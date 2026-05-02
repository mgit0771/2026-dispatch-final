#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="dispatch-review-merge"
TARGET_PATH_BASE="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

PROJECT=""
WORKER_NAME="w1"
TARGET_REPO=""
REVIEW_PROMPT_FILE=""
MODE="gate"
MAX_WAIT_SEC=1800
TEARDOWN=0
SCRIPTS_DIR="/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts"
DRY_RUN=0

PROJECT_USER=""
PROJECT_DIR=""
TARGET_HOME=""
TARGET_PATH=""
WORKER_FINAL=""
REVIEW_SESSION_ID=""
REVIEW_COST_USD=""
REVIEW_VERDICT=""
REVIEW_RESULT=""
REVIEW_LOG=""
MERGE_SESSION_ID=""
MERGE_COST_USD=""
MERGE_STATUS=""
MERGED_SHA=""
MERGE_LOG=""
MERGE_PROMPT_FILE=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/dispatch-review-merge.sh --project PROJECT --target-repo OWNER/REPO --review-prompt-file /abs/path/review.md [--worker-name NAME] [--mode gate|auto] [--max-wait-sec N] [--teardown] [--scripts-dir DIR] [--dry-run]
EOF
}

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
die() { local code="$1"; shift; printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit "$code"; }
need() { [ -n "${2:-}" ] || die 1 "Option '$1' requires a value."; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die 1 "Required command not found: $1"; }
is_root() { [ "$(id -u)" -eq 0 ]; }

lookup_user_home() {
  local passwd_entry=""

  passwd_entry="$(getent passwd "$1" || true)"
  [ -n "$passwd_entry" ] || return 1
  printf '%s\n' "$passwd_entry" | cut -d: -f6
}

positive_integer() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      [ "$1" -gt 0 ]
      ;;
  esac
}

claude_hours() {
  python3 -c 'import json,sys,time; data=json.load(open(sys.argv[1], "r", encoding="utf-8")); exp=float(data["claudeAiOauth"]["expiresAt"]); exp=exp/1000.0 if exp > 10**12 else exp; rem=exp-time.time(); print(f"{rem/3600:.1f}"); raise SystemExit(0 if rem > 3600 else 1)' \
    /home/claudeuser/.claude/.credentials.json
}

normalize_origin_repo() {
  local repo="$1"

  case "$repo" in
    https://github.com/*) repo="${repo#https://github.com/}" ;;
    http://github.com/*) repo="${repo#http://github.com/}" ;;
    git@github.com:*) repo="${repo#git@github.com:}" ;;
    ssh://git@github.com/*) repo="${repo#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac

  repo="${repo%.git}"
  repo="${repo%/}"
  printf '%s\n' "$repo"
}

latest_final_file() {
  local dir="/root/codex-headless/${PROJECT}/${WORKER_NAME}"

  [ -d "$dir" ] || return 1
  find "$dir" -maxdepth 1 -type f -name 'final-*.txt' -size +0c -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n 1 | cut -d' ' -f2-
}

json_line_from_log() {
  local log_file="$1"
  local json_line=""

  json_line="$(grep -E '^\{.*\}$' "$log_file" 2>/dev/null | tail -n 1 || true)"
  [ -n "$json_line" ] || return 1
  printf '%s\n' "$json_line"
}

wait_for_pid() {
  local pid="$1"
  local interval="${2:-5}"
  local status=0

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$interval"
  done

  set +e
  wait "$pid"
  status=$?
  set -e
  return "$status"
}

validate_args() {
  [ -n "$PROJECT" ] || die 1 "--project is required."
  [ -n "$TARGET_REPO" ] || die 1 "--target-repo is required."
  [ -n "$REVIEW_PROMPT_FILE" ] || die 1 "--review-prompt-file is required."
  [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die 1 "--project must match ^[a-z0-9][a-z0-9-]*$."
  [[ "$WORKER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 1 "--worker-name contains unsupported characters."
  [[ "$TARGET_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 1 "--target-repo must be OWNER/REPO."
  [[ "$REVIEW_PROMPT_FILE" = /* ]] || die 1 "--review-prompt-file must be an absolute path."
  [ -f "$REVIEW_PROMPT_FILE" ] || die 1 "Review prompt file not found: $REVIEW_PROMPT_FILE"
  [ -r "$REVIEW_PROMPT_FILE" ] || die 1 "Review prompt file is not readable: $REVIEW_PROMPT_FILE"
  positive_integer "$MAX_WAIT_SEC" || die 1 "--max-wait-sec must be a positive integer."
  case "$MODE" in
    gate|auto) ;;
    *) die 1 "--mode must be gate or auto." ;;
  esac

  PROJECT_USER="ccuser-${PROJECT}"
  PROJECT_DIR="/root/2026-loop/repo-${PROJECT}"
}

phase0() {
  local hours="" origin_url="" origin_repo=""

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Phase 0 (pre-flight): DRY-RUN, validated flags and prompt path"
    return 0
  fi

  is_root || die 1 "Run as root for live review/merge, or add --dry-run."
  need_cmd python3
  need_cmd jq
  need_cmd gh
  need_cmd claude
  need_cmd pgrep
  need_cmd find
  need_cmd grep
  need_cmd stat
  need_cmd sudo
  hours="$(claude_hours)" || die 1 "claudeuser credentials are unreadable or expire within 1h."
  [ -f "$SCRIPTS_DIR/ccc-headless-task.sh" ] || die 1 "Missing ccc-headless-task.sh under $SCRIPTS_DIR"
  [ -d "$PROJECT_DIR" ] || die 1 "Trusted project repo not found: $PROJECT_DIR"
  [ -e "$PROJECT_DIR/.git" ] || die 1 "Trusted project repo is missing .git metadata: $PROJECT_DIR"
  id "$PROJECT_USER" >/dev/null 2>&1 || die 1 "Worker user not found: $PROJECT_USER"
  TARGET_HOME="$(lookup_user_home "$PROJECT_USER" || true)"
  [ -n "$TARGET_HOME" ] || die 1 "Unable to resolve home for $PROJECT_USER"
  TARGET_PATH="${TARGET_HOME}/.npm-global/bin:/root/.npm-global/bin:${TARGET_PATH_BASE}"
  origin_url="$(git -C "$PROJECT_DIR" config --get remote.origin.url 2>/dev/null || true)"
  origin_repo="$(normalize_origin_repo "$origin_url" || true)"
  [ -n "$origin_repo" ] || die 1 "Could not resolve remote.origin.url for $PROJECT_DIR"
  [ "$origin_repo" = "$TARGET_REPO" ] || die 1 "Project repo origin mismatch: expected $TARGET_REPO, got $origin_repo"
  gh auth status --hostname github.com >/dev/null 2>&1 || die 1 "gh CLI is not authenticated for the current shell."
  sudo -u "$PROJECT_USER" env HOME="$TARGET_HOME" PATH="$TARGET_PATH" bash -lc 'command -v claude >/dev/null 2>&1' \
    || die 1 "claude CLI not available for $PROJECT_USER"
  sudo -u "$PROJECT_USER" env HOME="$TARGET_HOME" PATH="$TARGET_PATH" gh auth status --hostname github.com >/dev/null 2>&1 \
    || die 1 "gh CLI is not authenticated for $PROJECT_USER"
  log "Phase 0 (pre-flight): OK (claude=${hours}h, repo=${TARGET_REPO}, user=${PROJECT_USER}, mode=${MODE}, teardown=${TEARDOWN})"
}

phase7() {
  local start_sec="$SECONDS"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Phase 7 (wait worker DONE): DRY-RUN, would poll codex exec and inspect /root/codex-headless/${PROJECT}/${WORKER_NAME}/final-*.txt"
    WORKER_FINAL="/root/codex-headless/${PROJECT}/${WORKER_NAME}/final-DRY-RUN.txt"
    printf 'worker_final=%s\n' "$WORKER_FINAL"
    return 0
  fi

  while :; do
    if pgrep -f -- "codex exec.*${PROJECT}" >/dev/null 2>&1; then
      [ $((SECONDS - start_sec)) -lt "$MAX_WAIT_SEC" ] || die 4 "Timed out waiting for worker completion after ${MAX_WAIT_SEC}s."
      sleep 25
      continue
    fi

    WORKER_FINAL="$(latest_final_file || true)"
    [ -n "$WORKER_FINAL" ] || die 4 "Worker process is gone but no non-empty final output was found under /root/codex-headless/${PROJECT}/${WORKER_NAME}."
    log "Phase 7 (wait worker DONE): worker complete"
    printf 'worker_final=%s\n' "$WORKER_FINAL"
    return 0
  done
}

phase8() {
  local review_pid="" review_status=0 review_json="" is_error=""

  REVIEW_LOG="/tmp/${PROJECT}-review.log"

  if [ "$DRY_RUN" -eq 1 ]; then
    REVIEW_SESSION_ID="dry-run-session"
    REVIEW_COST_USD="0"
    REVIEW_VERDICT="PASS"
    REVIEW_RESULT="VERDICT: PASS"
    log "Phase 8 (CCC review): DRY-RUN, would run pre-merge-review via ${SCRIPTS_DIR}/ccc-headless-task.sh"
    printf 'review_verdict=%s\nreview_session_id=%s\nreview_cost_usd=%s\n' \
      "$REVIEW_VERDICT" "$REVIEW_SESSION_ID" "$REVIEW_COST_USD"
    return 0
  fi

  : >"$REVIEW_LOG"
  nohup bash "$SCRIPTS_DIR/ccc-headless-task.sh" \
    --project "$PROJECT" \
    --task pre-merge-review \
    --prompt-file "$REVIEW_PROMPT_FILE" \
    --user "$PROJECT_USER" \
    --output-format json >"$REVIEW_LOG" 2>&1 &
  review_pid=$!

  set +e
  wait_for_pid "$review_pid" 5
  review_status=$?
  set -e
  [ "$review_status" -eq 0 ] || die 5 "CCC review failed with status ${review_status}. Check ${REVIEW_LOG}."
  review_json="$(json_line_from_log "$REVIEW_LOG" || true)"
  [ -n "$review_json" ] || die 5 "Could not find JSON output in ${REVIEW_LOG}."
  is_error="$(printf '%s\n' "$review_json" | jq -r '.is_error // false')"
  [ "$is_error" = "false" ] || die 5 "CCC review returned is_error=true. Check ${REVIEW_LOG}."
  REVIEW_SESSION_ID="$(printf '%s\n' "$review_json" | jq -r '.session_id // empty')"
  REVIEW_COST_USD="$(printf '%s\n' "$review_json" | jq -r '(.total_cost_usd // empty) | tostring')"
  REVIEW_RESULT="$(printf '%s\n' "$review_json" | jq -r '.result // empty')"
  [ -n "$REVIEW_SESSION_ID" ] || die 5 "Review JSON did not include session_id."
  [ -n "$REVIEW_RESULT" ] || die 5 "Review JSON did not include result."
  if [[ "$REVIEW_RESULT" =~ VERDICT:[[:space:]]*(PASS|WARN|FAIL) ]]; then
    REVIEW_VERDICT="${BASH_REMATCH[1]}"
  else
    die 5 "Could not parse VERDICT: PASS|WARN|FAIL from the review result."
  fi

  log "Phase 8 (CCC review): complete"
  printf 'review_verdict=%s\nreview_session_id=%s\nreview_cost_usd=%s\n' \
    "$REVIEW_VERDICT" "$REVIEW_SESSION_ID" "${REVIEW_COST_USD:-unknown}"

  case "$REVIEW_VERDICT" in
    PASS)
      return 0
      ;;
    WARN)
      if [ "$MODE" = "gate" ]; then
        printf 'GATE: verdict=%s requires operator decision before merge\n' "$REVIEW_VERDICT"
        return 10
      fi
      printf 'AUTO: proceeding despite verdict=%s\n' "$REVIEW_VERDICT"
      ;;
    FAIL)
      if [ "$MODE" = "gate" ]; then
        printf 'GATE: verdict=%s requires operator decision before merge\n' "$REVIEW_VERDICT"
        return 11
      fi
      printf 'AUTO: proceeding despite verdict=%s\n' "$REVIEW_VERDICT"
      ;;
  esac
}

write_merge_prompt() {
  MERGE_PROMPT_FILE="/tmp/${PROJECT}-merge-prompt.md"

  cat >"$MERGE_PROMPT_FILE" <<EOF
Verdict was ${REVIEW_VERDICT}. Authorized merge.
Execute squash:
  cd /root/2026-loop/repo-${PROJECT}
  git fetch origin && git checkout main && git pull origin main
  git merge --squash origin/worker/${PROJECT}-${WORKER_NAME}
  git reset HEAD manifests/ 2>/dev/null || true
  rm -rf manifests/ 2>/dev/null || true
  git -c user.email='mg@fractals-ai.com' -c user.name='mgit0771' commit -m 'merge: ${WORKER_NAME} ${REVIEW_VERDICT}'
  git push origin main
  git push origin --delete worker/${PROJECT}-${WORKER_NAME}
Report: MERGE_STATUS, MERGED_SHA
EOF
}

phase9() {
  local merge_pid="" merge_status_code=0 merge_json="" merge_result="" merge_cmd="" is_error=""

  MERGE_LOG="/tmp/${PROJECT}-merge.log"

  if [ "$DRY_RUN" -eq 1 ]; then
    write_merge_prompt
    MERGE_SESSION_ID="$REVIEW_SESSION_ID"
    MERGE_COST_USD="0"
    MERGE_STATUS="success"
    MERGED_SHA="deadbee"
    log "Phase 9 (CCC merge): DRY-RUN, would resume session ${REVIEW_SESSION_ID} from ${PROJECT_DIR}"
    printf 'merge_status=%s\nmerge_session_id=%s\nmerge_cost_usd=%s\nmerged_sha=%s\n' \
      "$MERGE_STATUS" "$MERGE_SESSION_ID" "$MERGE_COST_USD" "$MERGED_SHA"
    return 0
  fi

  write_merge_prompt
  : >"$MERGE_LOG"
  printf -v merge_cmd \
    'cd %q && claude -p --resume %q --permission-mode bypassPermissions --output-format json --verbose < %q' \
    "$PROJECT_DIR" "$REVIEW_SESSION_ID" "$MERGE_PROMPT_FILE"
  nohup sudo -u "$PROJECT_USER" env HOME="$TARGET_HOME" PATH="$TARGET_PATH" bash -c "$merge_cmd" >"$MERGE_LOG" 2>&1 &
  merge_pid=$!

  set +e
  wait_for_pid "$merge_pid" 5
  merge_status_code=$?
  set -e
  [ "$merge_status_code" -eq 0 ] || die 6 "CCC merge failed with status ${merge_status_code}. Check ${MERGE_LOG}."
  merge_json="$(json_line_from_log "$MERGE_LOG" || true)"
  [ -n "$merge_json" ] || die 6 "Could not find JSON output in ${MERGE_LOG}."
  is_error="$(printf '%s\n' "$merge_json" | jq -r '.is_error // false')"
  [ "$is_error" = "false" ] || die 6 "CCC merge returned is_error=true. Check ${MERGE_LOG}."
  MERGE_SESSION_ID="$(printf '%s\n' "$merge_json" | jq -r '.session_id // empty')"
  MERGE_COST_USD="$(printf '%s\n' "$merge_json" | jq -r '(.total_cost_usd // empty) | tostring')"
  merge_result="$(printf '%s\n' "$merge_json" | jq -r '.result // empty')"
  [ -n "$MERGE_SESSION_ID" ] || die 6 "Merge JSON did not include session_id."
  [ "$MERGE_SESSION_ID" = "$REVIEW_SESSION_ID" ] || die 6 "Resume session mismatch: expected ${REVIEW_SESSION_ID}, got ${MERGE_SESSION_ID}."
  [ -n "$merge_result" ] || die 6 "Merge JSON did not include result."
  if [[ "$merge_result" =~ MERGED_SHA:[[:space:]]*([0-9a-fA-F]+) ]]; then
    MERGED_SHA="${BASH_REMATCH[1]}"
  else
    die 6 "Could not parse MERGED_SHA from the merge result."
  fi
  if [[ "$merge_result" =~ (MERGE_STATUS|STATUS):[[:space:]]*([A-Za-z0-9._-]+) ]]; then
    MERGE_STATUS="${BASH_REMATCH[2]}"
  else
    MERGE_STATUS="UNKNOWN"
  fi

  log "Phase 9 (CCC merge): complete"
  printf 'merge_status=%s\nmerge_session_id=%s\nmerge_cost_usd=%s\nmerged_sha=%s\n' \
    "$MERGE_STATUS" "$MERGE_SESSION_ID" "${MERGE_COST_USD:-unknown}" "$MERGED_SHA"
}

phase10() {
  local teardown_log="/tmp/${PROJECT}-teardown.log"

  [ "$TEARDOWN" -eq 1 ] || return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Phase 10 (teardown): DRY-RUN, would run /root/2026-loop/repo-comp-loop-env/scripts/teardown.sh --project ${PROJECT} --force"
    return 0
  fi

  bash /root/2026-loop/repo-comp-loop-env/scripts/teardown.sh --project "$PROJECT" --force >"$teardown_log" 2>&1 \
    || die 7 "Teardown failed. Check ${teardown_log}."
  log "Phase 10 (teardown): Teardown done"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project|--worker-name|--target-repo|--review-prompt-file|--mode|--max-wait-sec|--scripts-dir)
      need "$1" "${2:-}"
      case "$1" in
        --project) PROJECT="$2" ;;
        --worker-name) WORKER_NAME="$2" ;;
        --target-repo) TARGET_REPO="$2" ;;
        --review-prompt-file) REVIEW_PROMPT_FILE="$2" ;;
        --mode) MODE="$2" ;;
        --max-wait-sec) MAX_WAIT_SEC="$2" ;;
        --scripts-dir) SCRIPTS_DIR="$2" ;;
      esac
      shift 2
      ;;
    --teardown) TEARDOWN=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die 1 "Unknown argument: $1" ;;
  esac
done

validate_args
log "PROJECT=${PROJECT}"
log "TARGET_REPO=${TARGET_REPO}"
log "WORKER_NAME=${WORKER_NAME}, MODE=${MODE}, MAX_WAIT_SEC=${MAX_WAIT_SEC}, TEARDOWN=${TEARDOWN}, DRY_RUN=${DRY_RUN}"
phase0
phase7

phase8_status=0
set +e
phase8
phase8_status=$?
set -e
case "$phase8_status" in
  0) ;;
  10|11) exit "$phase8_status" ;;
  *) exit "$phase8_status" ;;
esac

phase9
phase10
log "DONE — review/merge orchestration complete"
