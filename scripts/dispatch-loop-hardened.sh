#!/usr/bin/env bash
set -euo pipefail

: "${DISPATCH_HOME:?DISPATCH_HOME must be set}"

SCRIPT_NAME="dispatch-loop-hardened"
PROJECT=""; MANIFEST_FILE=""; TARGET_REPO=""; REVIEW_PROMPT_FILE=""
WORKER_NAME="w1"; MODE="gate"; CREATE_REPO=0; TEARDOWN=0; MAX_WAIT_SEC=1800
SCRIPTS_DIR="${DISPATCH_LOOP_SCRIPTS_DIR:-${DISPATCH_HOME}/dispatch/scripts}"; DRY_RUN=0
CLAUDE_CREDENTIALS_FILE="${DISPATCH_LOOP_CLAUDE_CREDENTIALS_FILE:-/home/claudeuser/.claude/.credentials.json}"
LOOP_ROOT="${DISPATCH_LOOP_LOOP_ROOT:-${DISPATCH_HOME}/repos}"
TEARDOWN_SCRIPT="${DISPATCH_LOOP_TEARDOWN_SCRIPT:-${DISPATCH_HOME}/dispatch/scripts/teardown.sh}"
REVIEW_MERGE_SCRIPT="${DISPATCH_LOOP_REVIEW_MERGE_SCRIPT:-}"
F1_LOG=""; F2_LOG=""; THREAD_ID=""; PR_URL=""
REVIEW_VERDICT=""; REVIEW_SESSION_ID=""; REVIEW_COST_USD=""
MERGE_SESSION_ID=""; MERGE_COST_USD=""; MERGE_STATUS=""; MERGED_SHA=""
PRE_MERGE_SHA=""
SUMMARY_STATUS="error"; SUPPRESS_SUMMARY=0
declare -a PHASES_RUN=() ERRORS=()

usage() {
  cat <<'EOF'
Usage:
  ./scripts/dispatch-loop-hardened.sh --project PROJECT --manifest-file /abs/path/manifest.md --target-repo OWNER/REPO --review-prompt-file /abs/path/review.md [--worker-name NAME] [--mode gate|auto] [--create-repo] [--teardown] [--max-wait-sec N] [--scripts-dir DIR] [--dry-run]
EOF
}

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; }
need() { [ -n "${2:-}" ] || die 1 error "Option '$1' requires a value."; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die 1 error "Required command not found: $1"; }
positive_integer() { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "$1" -gt 0 ] ;; esac; }
json_arr() { if [ "$#" -eq 0 ]; then printf '[]\n'; else printf '%s\n' "$@" | jq -R . | jq -s .; fi; }
last_kv() { [ -f "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | tail -n 1; }

die() {
  local code="$1" status="$2"
  shift 2
  SUMMARY_STATUS="$status"
  if [ "$#" -gt 0 ]; then ERRORS+=("$*"); err "$*"; fi
  exit "$code"
}

claude_hours() {
  python3 - "$CLAUDE_CREDENTIALS_FILE" <<'PY'
import json
import sys
import time

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
exp = float(data["claudeAiOauth"]["expiresAt"])
if exp > 10 ** 12:
    exp /= 1000.0
left = exp - time.time()
print(f"{left / 3600:.1f}")
raise SystemExit(0 if left > 3600 else 1)
PY
}

emit_summary() {
  local phases_json errors_json ccc_session_id
  phases_json="$(json_arr "${PHASES_RUN[@]}")"
  errors_json="$(json_arr "${ERRORS[@]}")"
  ccc_session_id="${MERGE_SESSION_ID:-$REVIEW_SESSION_ID}"
  jq -nc \
    --arg project "$PROJECT" \
    --arg status "$SUMMARY_STATUS" \
    --arg merged_sha "${MERGED_SHA:-}" \
    --arg pr_url "${PR_URL:-}" \
    --arg ccc_session_id "${ccc_session_id:-}" \
    --arg review_cost "${REVIEW_COST_USD:-}" \
    --arg merge_cost "${MERGE_COST_USD:-}" \
    --argjson phases_run "$phases_json" \
    --argjson errors "$errors_json" '
      def maybe($s): if ($s|length)>0 then $s else null end;
      def num_or_null($s): if ($s|test("^[0-9]+(\\.[0-9]+)?$")) then ($s|tonumber) else null end;
      {
        project: maybe($project),
        status: $status,
        merged_sha: maybe($merged_sha),
        pr_url: maybe($pr_url),
        ccc_session_id: maybe($ccc_session_id),
        cost_estimate: {
          review_usd: num_or_null($review_cost),
          merge_usd: num_or_null($merge_cost),
          total_usd: (if num_or_null($review_cost) != null and num_or_null($merge_cost) != null then (num_or_null($review_cost) + num_or_null($merge_cost)) else null end)
        },
        phases_run: $phases_run,
        errors: $errors
      }'
}

on_exit() {
  local code="$1"
  [ "$SUPPRESS_SUMMARY" -eq 1 ] && return 0
  if [ "$code" -ne 0 ] && [ "${#ERRORS[@]}" -eq 0 ]; then ERRORS+=("Unexpected exit with status ${code}."); fi
  emit_summary
}
trap 'on_exit $?' EXIT

repo_origin_main_sha() {
  local repo="${LOOP_ROOT}/${PROJECT}"

  git -C "$repo" fetch origin main >/dev/null 2>&1 || return 1
  git -C "$repo" rev-parse origin/main 2>/dev/null
}

worker_still_running() {
  pgrep -f -- "codex exec.*-C ${LOOP_ROOT}/${PROJECT}/" >/dev/null 2>&1
}

validate_args() {
  [ -n "$PROJECT" ] || die 1 error "--project is required."
  [ -n "$MANIFEST_FILE" ] || die 1 error "--manifest-file is required."
  [ -n "$TARGET_REPO" ] || die 1 error "--target-repo is required."
  [ -n "$REVIEW_PROMPT_FILE" ] || die 1 error "--review-prompt-file is required."
  [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die 1 error "--project must match ^[a-z0-9][a-z0-9-]*$."
  [[ "$WORKER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 1 error "--worker-name contains unsupported characters."
  [[ "$TARGET_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 1 error "--target-repo must be OWNER/REPO."
  [[ "$MANIFEST_FILE" = /* ]] || die 1 error "--manifest-file must be an absolute path."
  [[ "$REVIEW_PROMPT_FILE" = /* ]] || die 1 error "--review-prompt-file must be an absolute path."
  [ -f "$MANIFEST_FILE" ] || die 1 error "Manifest file not found: $MANIFEST_FILE"
  [ -r "$MANIFEST_FILE" ] || die 1 error "Manifest file is not readable: $MANIFEST_FILE"
  [ -f "$REVIEW_PROMPT_FILE" ] || die 1 error "Review prompt file not found: $REVIEW_PROMPT_FILE"
  [ -r "$REVIEW_PROMPT_FILE" ] || die 1 error "Review prompt file is not readable: $REVIEW_PROMPT_FILE"
  positive_integer "$MAX_WAIT_SEC" || die 1 error "--max-wait-sec must be a positive integer."
  case "$MODE" in gate|auto) ;; *) die 1 error "--mode must be gate or auto." ;; esac

  if [ -z "$REVIEW_MERGE_SCRIPT" ]; then
    REVIEW_MERGE_SCRIPT="${SCRIPTS_DIR}/dispatch-review-merge-hardened.sh"
  fi
}

phase_a() {
  local account_len hours
  PHASES_RUN+=("A")
  for cmd in awk find grep jq python3 sed tee; do need_cmd "$cmd"; done
  account_len=$(( ${#PROJECT} + 7 ))
  [ "${#PROJECT}" -le 25 ] || die 1 error "B29: --project '${PROJECT}' is too long. 'ccuser-${PROJECT}' would exceed the POSIX 32-char login limit."
  [ "$account_len" -le 32 ] || die 1 error "B29: project slug is too long for worker user creation. 'ccuser-${PROJECT}' would be ${account_len} chars; max is 32."
  rm -f -- "/tmp/${PROJECT}-${WORKER_NAME}-manifest.md" "/tmp/${PROJECT}-${WORKER_NAME}-merge-prompt.md" "/tmp/${PROJECT}-merge-prompt.md" "/tmp/${PROJECT}-dispatch.log" "/tmp/${PROJECT}-review.log" "/tmp/${PROJECT}-merge.log" "/tmp/${PROJECT}-loop-f1.log" "/tmp/${PROJECT}-loop-f2.log"
  [ -x "${SCRIPTS_DIR}/dispatch-pre.sh" ] || die 1 error "Missing or not executable: ${SCRIPTS_DIR}/dispatch-pre.sh"
  [ -x "$REVIEW_MERGE_SCRIPT" ] || die 1 error "Missing or not executable: $REVIEW_MERGE_SCRIPT"
  hours="$(claude_hours)" || die 1 error "claudeuser credentials are unreadable or expire within 1h: $CLAUDE_CREDENTIALS_FILE"
  log "Phase A (pre-flight): OK (project=${PROJECT}, user=ccuser-${PROJECT}, claude=${hours}h, scripts_dir=${SCRIPTS_DIR}, dry_run=${DRY_RUN})"
}

phase_b() {
  local f1_exit
  local -a cmd=(bash "${SCRIPTS_DIR}/dispatch-pre.sh" --project "$PROJECT" --manifest-file "$MANIFEST_FILE" --target-repo "$TARGET_REPO" --worker-name "$WORKER_NAME")
  PHASES_RUN+=("B")
  F1_LOG="/tmp/${PROJECT}-loop-f1.log"
  [ "$CREATE_REPO" -eq 1 ] && cmd+=(--create-repo)
  [ "$DRY_RUN" -eq 1 ] && cmd+=(--dry-run)
  log "Phase B (F1 invoke): start, log=${F1_LOG}"
  set +e
  "${cmd[@]}" 2>&1 | tee "$F1_LOG"
  f1_exit=${PIPESTATUS[0]}
  set -e
  [ "$f1_exit" -eq 0 ] || die "$f1_exit" error "F1 failed with status ${f1_exit}. Check ${F1_LOG}."
  THREAD_ID="$(sed -n 's/.*Phase 7 (verify): thread_id=\([^,[:space:]]*\).*/\1/p' "$F1_LOG" | tail -n 1)"
  if [ -z "$THREAD_ID" ] && [ "$DRY_RUN" -eq 1 ]; then THREAD_ID="dry-run-thread"; fi
  [ -n "$THREAD_ID" ] || die 2 error "F1 completed but thread_id was not found in ${F1_LOG}."
  PR_URL="$(sed -n 's/.*pr=\(https:\/\/[^ ,]*\).*/\1/p' "$F1_LOG" | tail -n 1)"
  log "Phase B (F1 invoke): f1_status=ok thread_id=${THREAD_ID}${PR_URL:+ pr_url=${PR_URL}}"
}

load_f2_kv() {
  local merged_sha=""
  REVIEW_VERDICT="$(last_kv "$F2_LOG" review_verdict)"
  REVIEW_SESSION_ID="$(last_kv "$F2_LOG" review_session_id)"
  REVIEW_COST_USD="$(last_kv "$F2_LOG" review_cost_usd)"
  MERGE_STATUS="$(last_kv "$F2_LOG" merge_status)"
  MERGE_SESSION_ID="$(last_kv "$F2_LOG" merge_session_id)"
  MERGE_COST_USD="$(last_kv "$F2_LOG" merge_cost_usd)"
  merged_sha="$(last_kv "$F2_LOG" merged_sha)"
  if [ -n "$merged_sha" ]; then MERGED_SHA="$merged_sha"; fi
}

recover_b30() {
  local merge_log="/tmp/${PROJECT}-merge.log" merge_result="" merged_sha="" post_merge_sha=""

  [ -f "$merge_log" ] || return 1
  merge_result="$(jq -r '.. | objects | .result? // empty' "$merge_log" 2>/dev/null || true)"
  merged_sha="$(printf '%s\n' "$merge_result" | grep -oE 'MERGED_SHA: [A-Fa-f0-9]+' | awk '{print $2}' | head -n 1 || true)"
  if [ -z "$merged_sha" ]; then
    merged_sha="$(grep -oE 'MERGED_SHA: [A-Fa-f0-9]+' "$merge_log" 2>/dev/null | awk '{print $2}' | head -n 1 || true)"
  fi
  if [ -n "$merged_sha" ]; then
    MERGED_SHA="$merged_sha"
  else
    post_merge_sha="$(repo_origin_main_sha || true)"
    if [ -n "$PRE_MERGE_SHA" ] && [ -n "$post_merge_sha" ] && [ "$post_merge_sha" != "$PRE_MERGE_SHA" ]; then
      MERGED_SHA="$post_merge_sha"
      log "Phase C: B30 git-log fallback accepted (origin/main changed ${PRE_MERGE_SHA:0:7} -> ${post_merge_sha:0:7})"
    else
      if [ -n "$PRE_MERGE_SHA" ]; then
        log "Phase C: B30 git-log fallback REJECTED (origin/main unchanged at ${PRE_MERGE_SHA:0:7}, no merge happened)"
      else
        log "Phase C: B30 git-log fallback REJECTED (pre-merge origin/main snapshot unavailable)"
      fi
      return 1
    fi
  fi

  if [ -z "$MERGE_SESSION_ID" ]; then MERGE_SESSION_ID="$(jq -r '.. | objects | .session_id? // empty' "$merge_log" 2>/dev/null | tail -n 1 || true)"; fi
  if [ -z "$MERGE_COST_USD" ]; then MERGE_COST_USD="$(jq -r '.. | objects | .total_cost_usd? // empty' "$merge_log" 2>/dev/null | tail -n 1 || true)"; fi
  if [ -z "$MERGE_STATUS" ]; then MERGE_STATUS="$(printf '%s\n' "$merge_result" | grep -oE '(MERGE_STATUS|STATUS): [A-Za-z0-9._-]+' | awk '{print $2}' | head -n 1 || true)"; fi
  [ -n "$MERGE_STATUS" ] || MERGE_STATUS="recovered_b30"
}

phase_d() {
  local manifest_tmp="/tmp/${PROJECT}-${WORKER_NAME}-manifest.md"
  local worktree="${LOOP_ROOT}/${PROJECT}/.letta/worktrees/worker-${PROJECT}-${WORKER_NAME}"
  local -a find_cmd=(find "$worktree" -path "$worktree/.git" -prune -o -type f)
  local -a crash_files=()
  PHASES_RUN+=("D")
  if grep -Fq "Timed out waiting for worker completion" "$F2_LOG" && worker_still_running; then
    die 4 error "Worker is still running after ${MAX_WAIT_SEC}s. Increase --max-wait-sec or rerun later."
  fi
  [ -d "$worktree" ] || die 4 error "F2 phase 7 failed and worker worktree was not found: $worktree"
  if [ -f "$manifest_tmp" ]; then find_cmd+=(-newer "$manifest_tmp"); fi
  find_cmd+=(-print)
  while IFS= read -r file; do [ -z "$file" ] || crash_files+=("$file"); done < <("${find_cmd[@]}" | sort)
  if [ "${#crash_files[@]}" -gt 0 ]; then
    SUMMARY_STATUS="crash"
    ERRORS+=("WORKER_CRASH_DETECTED: files preserved in worktree, manual review needed.")
    log "Phase D (recovery): WORKER_CRASH_DETECTED: files preserved in worktree, manual review needed"
    printf 'recovery_hint=cd %s && git status && git add -A && git commit\n' "${LOOP_ROOT}/${PROJECT}"
    printf '%s\n' "${crash_files[@]}" | sed 's/^/crash_file=/'
    exit 7
  fi
  die 4 error "F2 phase 7 failed and no preserved worktree files were found."
}

maybe_teardown_after_recovery() {
  local teardown_log="/tmp/${PROJECT}-teardown.log"
  [ "$TEARDOWN" -eq 1 ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ -x "$TEARDOWN_SCRIPT" ] || die 7 error "Recovered merge but teardown script is missing or not executable: $TEARDOWN_SCRIPT"
  bash "$TEARDOWN_SCRIPT" --project "$PROJECT" --force >"$teardown_log" 2>&1 || die 7 error "Recovered merge but teardown failed. Check ${teardown_log}."
  log "Phase C (F2 invoke): teardown completed after B30 recovery"
}

phase_c() {
  local f2_exit
  local -a cmd=(bash "$REVIEW_MERGE_SCRIPT" --project "$PROJECT" --target-repo "$TARGET_REPO" --review-prompt-file "$REVIEW_PROMPT_FILE" --worker-name "$WORKER_NAME" --mode "$MODE" --max-wait-sec "$MAX_WAIT_SEC")
  PHASES_RUN+=("C")
  F2_LOG="/tmp/${PROJECT}-loop-f2.log"
  PRE_MERGE_SHA="$(repo_origin_main_sha || true)"
  [ "$TEARDOWN" -eq 1 ] && cmd+=(--teardown)
  [ "$DRY_RUN" -eq 1 ] && cmd+=(--dry-run)
  log "Phase C (F2 invoke): start, log=${F2_LOG}"
  set +e
  "${cmd[@]}" 2>&1 | tee "$F2_LOG"
  f2_exit=${PIPESTATUS[0]}
  set -e
  load_f2_kv
  case "$f2_exit" in
    0)
      [ -n "$MERGED_SHA" ] || die 6 error "F2 succeeded but merged_sha was not found in ${F2_LOG}."
      SUMMARY_STATUS="merged"; log "Phase C (F2 invoke): f2_status=ok merged_sha=${MERGED_SHA}" ;;
    6)
      if recover_b30; then
        maybe_teardown_after_recovery
        SUMMARY_STATUS="merged"; log "Phase C (F2 invoke): f2_status=recovered_b30 merged_sha=${MERGED_SHA}"
      else
        die 6 error "F2 exited 6 and B30 recovery could not determine MERGED_SHA. Check ${F2_LOG} and /tmp/${PROJECT}-merge.log."
      fi ;;
    10) SUMMARY_STATUS="gate_warn"; log "Phase C (F2 invoke): f2_status=gate_warn verdict=${REVIEW_VERDICT:-WARN}"; exit 10 ;;
    11) SUMMARY_STATUS="gate_fail"; log "Phase C (F2 invoke): f2_status=gate_fail verdict=${REVIEW_VERDICT:-FAIL}"; exit 11 ;;
    4) phase_d ;;
    *) die "$f2_exit" error "F2 failed with status ${f2_exit}. Check ${F2_LOG}." ;;
  esac
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project|--manifest-file|--target-repo|--review-prompt-file|--worker-name|--mode|--max-wait-sec|--scripts-dir)
        need "$1" "${2:-}"
        case "$1" in
          --project) PROJECT="$2" ;;
          --manifest-file) MANIFEST_FILE="$2" ;;
          --target-repo) TARGET_REPO="$2" ;;
          --review-prompt-file) REVIEW_PROMPT_FILE="$2" ;;
          --worker-name) WORKER_NAME="$2" ;;
          --mode) MODE="$2" ;;
          --max-wait-sec) MAX_WAIT_SEC="$2" ;;
          --scripts-dir) SCRIPTS_DIR="$2" ;;
        esac
        shift 2 ;;
      --create-repo) CREATE_REPO=1; shift ;;
      --teardown) TEARDOWN=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --help|-h) SUPPRESS_SUMMARY=1; usage; exit 0 ;;
      *) die 1 error "Unknown argument: $1" ;;
    esac
  done
  validate_args
  log "PROJECT=${PROJECT}"
  log "TARGET_REPO=${TARGET_REPO}"
  log "WORKER_NAME=${WORKER_NAME}, MODE=${MODE}, MAX_WAIT_SEC=${MAX_WAIT_SEC}, TEARDOWN=${TEARDOWN}, DRY_RUN=${DRY_RUN}"
  phase_a
  phase_b
  phase_c
  log "Phase E (final): dispatch loop complete"
}

main "$@"
