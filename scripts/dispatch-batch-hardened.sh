#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2030,SC2031
set -euo pipefail

: "${DISPATCH_HOME:?DISPATCH_HOME must be set}"

SCRIPT_NAME="dispatch-batch-hardened"
TARGET_PATH_BASE="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

PROJECT_PREFIX=""
MANIFESTS_DIR=""
TARGET_REPO_TEMPLATE=""
REVIEW_PROMPT_FILE=""
MODE="gate"
MAX_PARALLEL=3
MAX_WAIT_SEC=1800
TEARDOWN=0
SCRIPTS_DIR="${DISPATCH_BATCH_SCRIPTS_DIR:-${DISPATCH_HOME}/dispatch/scripts}"
DRY_RUN=0

ANTHROPIC_KEY_FILE="${DISPATCH_BATCH_ANTHROPIC_KEY_FILE:-${DISPATCH_HOME}/.config/anthropic-api-key}"
LOOP_ROOT="${DISPATCH_BATCH_LOOP_ROOT:-${DISPATCH_HOME}/repos}"
CODEX_HEADLESS_ROOT="${DISPATCH_BATCH_CODEX_HEADLESS_ROOT:-${DISPATCH_HOME}/.codex-headless}"
CCC_HEADLESS_ROOT="${DISPATCH_BATCH_CCC_HEADLESS_ROOT:-${DISPATCH_HOME}/.ccc-headless}"
CCC_TASK_SCRIPT="${DISPATCH_BATCH_CCC_TASK_SCRIPT:-${SCRIPTS_DIR}/ccc-headless-task.sh}"
TEARDOWN_SCRIPT="${DISPATCH_BATCH_TEARDOWN_SCRIPT:-${DISPATCH_HOME}/dispatch/scripts/teardown.sh}"
STAGGER_SEC="${DISPATCH_BATCH_STAGGER_SEC:-5}"
: "${CCC_HEADLESS_ROOT}"

REVIEW_LOG=""
REVIEW_PROMPT_RENDERED=""
REVIEW_SESSION_ID=""
REVIEW_COST_USD=""
REVIEW_RESULT=""
MERGE_LOG=""
MERGE_PROMPT_RENDERED=""
MERGE_SESSION_ID=""
MERGE_COST_USD=""
MERGE_RESULT=""
FINAL_STATUS=""
SUMMARY_SUPPRESSED=0

BATCH_PROJECT=""
BATCH_USER=""
BATCH_HOME=""
BATCH_PATH=""
ANCHOR_ERROR=""

declare -a PHASES_RUN=() ERRORS=() WORKERS=() REVIEWABLE_WORKERS=() PASS_WORKERS=()
declare -A MANIFEST_PATHS PROJECTS TARGET_REPOS F1_LOGS THREAD_IDS FINAL_FILES PR_URLS HEAD_SHAS
declare -A VERDICTS MERGED_SHAS RESULT_STATUS START_SECS PRE_MERGE_SHAS

usage() {
  cat <<'EOF'
Usage:
  ./scripts/dispatch-batch-hardened.sh --project-prefix PREFIX --manifests-dir /abs/path --target-repo-template OWNER/REPO-{N} --review-prompt-file /abs/path/review.md [--mode gate|auto] [--max-parallel N] [--max-wait-sec N] [--scripts-dir DIR] [--teardown] [--dry-run]
EOF
}

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2; }
err() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; }
need() { [ -n "${2:-}" ] || die 1 "Option '$1' requires a value."; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die 1 "Required command not found: $1"; }
is_root() { [ "$(id -u)" -eq 0 ]; }
positive_integer() { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "$1" -gt 0 ] ;; esac; }
nonnegative_integer() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

add_error() {
  ERRORS+=("$*")
  err "$*"
}

die() {
  local code="$1"
  shift
  if [ "$#" -gt 0 ]; then
    add_error "$*"
  fi
  exit "$code"
}

json_arr() {
  if [ "$#" -eq 0 ]; then
    printf '[]\n'
  else
    printf '%s\n' "$@" | jq -R . | jq -s .
  fi
}

lookup_user_home() {
  local user_name="$1" passwd_entry=""
  passwd_entry="$(getent passwd "$user_name" || true)"
  [ -n "$passwd_entry" ] || return 1
  printf '%s\n' "$passwd_entry" | cut -d: -f6
}

json_object_from_log() {
  local log_file="$1" json_line=""

  json_line="$(jq -c '.[]? | select(type == "object")' "$log_file" 2>/dev/null | tail -n 1 || true)"
  if [ -z "$json_line" ]; then
    json_line="$(jq -c 'select(type == "object")' "$log_file" 2>/dev/null | tail -n 1 || true)"
  fi
  if [ -z "$json_line" ]; then
    json_line="$(grep -E '^\{.*\}$' "$log_file" 2>/dev/null | tail -n 1 || true)"
  fi
  printf '%s\n' "$json_line"
}

worker_number() { printf '%s\n' "${1#w}"; }

current_summary_status() {
  local total="${#WORKERS[@]}" merged=0 gated=0 crashed=0 other=0 worker status=""
  if [ -n "$FINAL_STATUS" ]; then
    printf '%s\n' "$FINAL_STATUS"
    return 0
  fi
  for worker in "${WORKERS[@]}"; do
    status="${RESULT_STATUS[$worker]:-pending}"
    case "$status" in
      merged) merged=$((merged + 1)) ;;
      gated) gated=$((gated + 1)) ;;
      crashed|dispatch_failed|no_pr|timed_out) crashed=$((crashed + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
  done
  if [ "$total" -gt 0 ] && [ "$merged" -eq "$total" ]; then
    printf 'all_merged\n'
  elif [ "$gated" -gt 0 ] && [ "$merged" -eq 0 ]; then
    printf 'gated\n'
  elif [ "$total" -gt 0 ] && [ "$crashed" -eq "$total" ]; then
    printf 'crashed\n'
  elif [ "$merged" -gt 0 ] || [ "$gated" -gt 0 ] || [ "$crashed" -gt 0 ] || [ "$other" -gt 0 ]; then
    printf 'partial\n'
  else
    printf 'error\n'
  fi
}

results_json() {
  local worker status project pr_url verdict merged_sha
  if [ "${#WORKERS[@]}" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi
  for worker in "${WORKERS[@]}"; do
    status="${RESULT_STATUS[$worker]:-pending}"
    project="${PROJECTS[$worker]:-}"
    pr_url="${PR_URLS[$worker]:-}"
    verdict="${VERDICTS[$worker]:-}"
    merged_sha="${MERGED_SHAS[$worker]:-}"
    jq -nc \
      --arg worker "$worker" \
      --arg project "$project" \
      --arg pr_url "$pr_url" \
      --arg verdict "$verdict" \
      --arg merged_sha "$merged_sha" \
      --arg status "$status" '
        def maybe($s): if ($s | length) > 0 then $s else null end;
        {
          worker: $worker,
          project: maybe($project),
          pr_url: maybe($pr_url),
          verdict: maybe($verdict),
          merged_sha: maybe($merged_sha),
          status: $status
        }'
  done | jq -s .
}

emit_summary() {
  local exit_code="$1" summary_status phases_json errors_json results_json_value ccc_session_id
  [ "$SUMMARY_SUPPRESSED" -eq 0 ] || return 0
  case " ${PHASES_RUN[*]} " in *" E "*) ;; *) PHASES_RUN+=("E") ;; esac
  if [ "$exit_code" -ne 0 ] && [ "${#ERRORS[@]}" -eq 0 ]; then
    ERRORS+=("Unexpected exit with status ${exit_code}.")
  fi
  summary_status="$(current_summary_status)"
  phases_json="$(json_arr "${PHASES_RUN[@]}")"
  errors_json="$(json_arr "${ERRORS[@]}")"
  results_json_value="$(results_json)"
  ccc_session_id="${MERGE_SESSION_ID:-$REVIEW_SESSION_ID}"
  jq -n \
    --arg batch_prefix "$PROJECT_PREFIX" \
    --arg status "$summary_status" \
    --arg ccc_session_id "${ccc_session_id:-}" \
    --arg review_cost "${REVIEW_COST_USD:-}" \
    --arg merge_cost "${MERGE_COST_USD:-}" \
    --argjson n_workers "${#WORKERS[@]}" \
    --argjson results_per_worker "$results_json_value" \
    --argjson phases_run "$phases_json" \
    --argjson errors "$errors_json" '
      def maybe($s): if ($s | length) > 0 then $s else null end;
      def num_or_null($s): if ($s | test("^[0-9]+(\\.[0-9]+)?$")) then ($s | tonumber) else null end;
      {
        batch_prefix: $batch_prefix,
        n_workers: $n_workers,
        status: $status,
        ccc_session_id: maybe($ccc_session_id),
        results_per_worker: $results_per_worker,
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
  emit_summary "$code"
}
trap 'on_exit $?' EXIT

need_gh_auth() {
  gh auth status --hostname github.com >/dev/null 2>&1 && return 0
  [ -n "${GITHUB_TOKEN:-}" ] || die 1 "GITHUB_TOKEN is required for repo creation and PR lookup."
  printf '%s\n' "$GITHUB_TOKEN" | gh auth login --hostname github.com --with-token >/dev/null 2>&1 \
    || die 1 "gh auth login failed for github.com."
  gh auth setup-git --hostname github.com >/dev/null 2>&1 || die 1 "gh auth setup-git failed for github.com."
}

ensure_target_repo() {
  local worker="$1" target_repo="" owner="" name="" login="" repo_url="" output="" status=0
  target_repo="${TARGET_REPOS[$worker]}"
  [ "$DRY_RUN" -eq 1 ] && return 0
  if repo_url="$(gh repo view "$target_repo" --json url --jq .url 2>/dev/null)"; then
    log "Phase B (target repo): ${worker} exists ${repo_url}"
    return 0
  fi
  owner="${target_repo%%/*}"
  name="${target_repo#*/}"
  login="$(gh api user --jq .login 2>/dev/null || true)"
  [ -n "$login" ] || { add_error "Unable to resolve authenticated GitHub user for ${worker}."; return 1; }
  [ "$owner" = "$login" ] || {
    add_error "Target repo does not exist and auto-create requires OWNER=${login}: ${target_repo}"
    return 1
  }
  set +e
  output="$(gh api --method POST /user/repos -f name="$name" -F auto_init=true -F private=true --jq .html_url 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    add_error "Failed to create ${target_repo}: ${output}"
    return 1
  fi
  log "Phase B (target repo): ${worker} created ${output}"
}

latest_final_file() {
  local project="$1" worker="$2" dir=""
  dir="${CODEX_HEADLESS_ROOT}/${project}/${worker}"
  [ -d "$dir" ] || return 1
  find "$dir" -maxdepth 1 -type f -name 'final-*.txt' -size +0c -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n 1 | cut -d' ' -f2-
}

worker_is_running() {
  pgrep -af -- "codex exec.*-C ${LOOP_ROOT}/${1}/" >/dev/null 2>&1
}

repo_origin_main_sha() {
  local repo="$1"

  git -C "$repo" fetch origin main >/dev/null 2>&1 || return 1
  git -C "$repo" rev-parse origin/main 2>/dev/null
}

wait_for_pr_metadata() {
  local worker="$1" project="" branch="" target_repo=""
  local deadline=$((SECONDS + 60)) json="" url="" sha=""
  project="${PROJECTS[$worker]}"
  branch="worker/${project}-${worker}"
  target_repo="${TARGET_REPOS[$worker]}"
  [ "$DRY_RUN" -eq 1 ] && return 0
  while [ "$SECONDS" -lt "$deadline" ]; do
    json="$(gh pr list --repo "$target_repo" --head "$branch" --state all --json url,number,headRefOid 2>/dev/null || true)"
    url="$(printf '%s\n' "$json" | jq -r '.[0].url // empty' 2>/dev/null || true)"
    if [ -n "$url" ]; then
      sha="$(printf '%s\n' "$json" | jq -r '.[0].headRefOid // empty' 2>/dev/null || true)"
      PR_URLS["$worker"]="$url"
      HEAD_SHAS["$worker"]="$sha"
      return 0
    fi
    sleep 5
  done
  return 1
}

select_batch_anchor() {
  local worker=""

  BATCH_PROJECT=""
  BATCH_USER=""
  BATCH_HOME=""
  BATCH_PATH=""
  ANCHOR_ERROR=""

  if [ -d "${LOOP_ROOT}/${PROJECT_PREFIX}" ]; then
    BATCH_PROJECT="$PROJECT_PREFIX"
  else
    for worker in "${REVIEWABLE_WORKERS[@]}"; do
      if [ -d "${LOOP_ROOT}/${PROJECTS[$worker]}" ]; then
        BATCH_PROJECT="${PROJECTS[$worker]}"
        break
      fi
    done
  fi

  [ -n "$BATCH_PROJECT" ] || {
    ANCHOR_ERROR="Batch anchor repo could not be resolved for prefix ${PROJECT_PREFIX}."
    return 1
  }

  BATCH_USER="ccuser-${BATCH_PROJECT}"
  BATCH_HOME="$(lookup_user_home "$BATCH_USER" || true)"
  [ -n "$BATCH_HOME" ] || {
    ANCHOR_ERROR="Batch anchor home could not be resolved for ${BATCH_USER}."
    return 1
  }
  BATCH_PATH="${BATCH_HOME}/.npm-global/bin:${DISPATCH_HOME}/.npm-global/bin:${TARGET_PATH_BASE}"
}

check_worker_claude_cli() {
  local worker="" worker_num="" project="" user="" home="" target_path="" failed=0

  for worker in "${WORKERS[@]}"; do
    worker_num="$(worker_number "$worker")"
    project="${PROJECTS[$worker]}"
    user="ccuser-${project}"
    if ! id "$user" >/dev/null 2>&1; then
      add_error "Worker ${worker_num} user not found: ${user}."
      failed=1
      continue
    fi
    home="$(lookup_user_home "$user" || true)"
    if [ -z "$home" ]; then
      add_error "Worker ${worker_num} home could not be resolved for ${user}."
      failed=1
      continue
    fi
    target_path="${home}/.npm-global/bin:${DISPATCH_HOME}/.npm-global/bin:${TARGET_PATH_BASE}"
    if ! sudo -u "$user" env HOME="$home" PATH="$target_path" bash -lc 'command -v claude >/dev/null 2>&1'; then
      add_error "Worker ${worker_num} claude CLI not available for ${user}."
      failed=1
    fi
  done

  return "$failed"
}

build_review_context() {
  local worker num project branch
  for worker in "${REVIEWABLE_WORKERS[@]}"; do
    num="$(worker_number "$worker")"
    project="${PROJECTS[$worker]}"
    branch="worker/${project}-${worker}"
    printf 'PR #%s\n' "$num"
    printf 'project: %s\n' "$project"
    printf 'worker: %s\n' "$worker"
    printf 'target_repo: %s\n' "${TARGET_REPOS[$worker]}"
    printf 'local_repo: %s/%s\n' "$LOOP_ROOT" "$project"
    printf 'branch: %s\n' "$branch"
    printf 'manifest_file: %s\n' "${MANIFEST_PATHS[$worker]}"
    printf 'final_file: %s\n' "${FINAL_FILES[$worker]}"
    printf 'pr_url: %s\n' "${PR_URLS[$worker]}"
    printf 'head_sha: %s\n\n' "${HEAD_SHAS[$worker]:-unknown}"
  done
}

write_review_prompt() {
  local template rendered pr_context strict_lines has_pr_context=0
  REVIEW_PROMPT_RENDERED="/tmp/${PROJECT_PREFIX}-batch-review-prompt.md"
  template="$(<"$REVIEW_PROMPT_FILE")"
  pr_context="$(build_review_context)"
  case "$template" in *"{{PR_CONTEXT}}"*|*"__PR_CONTEXT__"*) has_pr_context=1 ;; esac
  rendered="${template//'{{BATCH_PREFIX}}'/$PROJECT_PREFIX}"
  rendered="${rendered//'{{N_WORKERS}}'/${#WORKERS[@]}}"
  rendered="${rendered//'{{READY_WORKERS}}'/${#REVIEWABLE_WORKERS[@]}}"
  rendered="${rendered//'{{PR_CONTEXT}}'/$pr_context}"
  rendered="${rendered//'__BATCH_PREFIX__'/$PROJECT_PREFIX}"
  rendered="${rendered//'__N_WORKERS__'/${#WORKERS[@]}}"
  rendered="${rendered//'__READY_WORKERS__'/${#REVIEWABLE_WORKERS[@]}}"
  rendered="${rendered//'__PR_CONTEXT__'/$pr_context}"
  strict_lines="Strict output:"$'\n'
  for worker in "${REVIEWABLE_WORKERS[@]}"; do
    strict_lines+="PR #$(worker_number "$worker"): PASS|WARN|FAIL"$'\n'
  done
  strict_lines+="CROSS_PR_FINDINGS: none | <text>"$'\n'
  strict_lines+="OVERALL_RECOMMENDATION: merge-all | merge-pass-only | gate"$'\n'
  strict_lines+="NEXT_STEP: awaiting Turn 2 merge instructions"
  umask 077
  {
    printf '%s\n\n' "$rendered"
    if [ "$has_pr_context" -eq 0 ]; then
      printf 'Batch context:\n%s\n' "$pr_context"
      printf '\n'
    fi
    printf 'Turn 1 only. Review every listed PR and cross-PR consistency. Do not merge in this turn.\n\n'
    printf '%s\n' "$strict_lines"
  } >"$REVIEW_PROMPT_RENDERED"
}

parse_review_verdicts() {
  local worker num verdict matrix=() non_pass=0
  PASS_WORKERS=()
  for worker in "${REVIEWABLE_WORKERS[@]}"; do
    num="$(worker_number "$worker")"
    verdict="$(printf '%s\n' "$REVIEW_RESULT" | sed -n "s/^PR #${num}: \\(PASS\\|WARN\\|FAIL\\).*$/\\1/p" | tail -n 1)"
    if [ -z "$verdict" ]; then
      verdict="$(grep -oE "PR #${num}: (PASS|WARN|FAIL)" "$REVIEW_LOG" 2>/dev/null | awk '{print $3}' | tail -n 1 || true)"
    fi
    [ -n "$verdict" ] || { verdict="FAIL"; add_error "Could not parse verdict for PR #${num}; defaulting to FAIL."; }
    VERDICTS["$worker"]="$verdict"
    matrix+=("PR#${num}=${verdict}")
    if [ "$verdict" = "PASS" ]; then
      PASS_WORKERS+=("$worker")
    else
      non_pass=1
    fi
  done
  log "Phase D (batch review): ${matrix[*]}"
  return "$non_pass"
}

write_merge_prompt() {
  local worker num project branch strict_lines=""
  MERGE_PROMPT_RENDERED="/tmp/${PROJECT_PREFIX}-batch-merge-prompt.md"
  strict_lines="Strict output:"$'\n'
  umask 077
  {
    printf 'Turn 2 resume for batch prefix %s.\n' "$PROJECT_PREFIX"
    printf 'Mode: %s\n\n' "$MODE"
    printf 'Verdicts:\n'
    for worker in "${REVIEWABLE_WORKERS[@]}"; do
      printf 'PR #%s = %s (%s)\n' "$(worker_number "$worker")" "${VERDICTS[$worker]}" "${PROJECTS[$worker]}"
    done
    printf '\n'
    printf 'In auto mode merge PASS PRs only, sequentially, and skip WARN/FAIL. Stop further merges on first conflict or push failure.\n'
    printf 'Each merge must be squash, reset manifests/, push main, then delete remote worker branch.\n'
    for worker in "${PASS_WORKERS[@]}"; do
      num="$(worker_number "$worker")"
      project="${PROJECTS[$worker]}"
      branch="worker/${project}-${worker}"
      printf '\nPR #%s merge steps:\n' "$num"
      printf 'cd %s/%s\n' "$LOOP_ROOT" "$project"
      printf 'git fetch origin --prune\n'
      printf 'git checkout main && git pull origin main --ff-only\n'
      printf 'git merge --squash origin/%s\n' "$branch"
      printf 'git reset HEAD manifests/ 2>/dev/null || true\n'
      printf 'rm -rf manifests/ 2>/dev/null || true\n'
      printf "git -c user.email='mg@fractals-ai.com' -c user.name='mgit0771' commit -m 'merge: %s PASS'\n" "$worker"
      printf 'git push origin main\n'
      printf 'git push origin --delete %s\n' "$branch"
    done
    printf '\n'
    for worker in "${REVIEWABLE_WORKERS[@]}"; do
      num="$(worker_number "$worker")"
      strict_lines+="PR #${num} MERGE_STATUS: merged|skipped_non_pass|conflict|aborted"$'\n'
      strict_lines+="PR #${num} MERGED_SHA: <sha-or-none>"$'\n'
    done
    strict_lines+="BATCH_STATUS: all_merged|partial|aborted"
    printf '%s\n' "$strict_lines"
  } >"$MERGE_PROMPT_RENDERED"
}

load_merge_output() {
  MERGE_SESSION_ID="$(jq -r '.. | objects | .session_id? // empty' "$MERGE_LOG" 2>/dev/null | tail -n 1 || true)"
  MERGE_COST_USD="$(jq -r '.. | objects | .total_cost_usd? // empty | tostring' "$MERGE_LOG" 2>/dev/null | tail -n 1 || true)"
  MERGE_RESULT="$(jq -r '.. | objects | .result? // empty' "$MERGE_LOG" 2>/dev/null || true)"
  if [ -z "$MERGE_RESULT" ] && [ -f "$MERGE_LOG" ]; then
    MERGE_RESULT="$(grep -E 'PR #[0-9]+ (MERGE_STATUS|MERGED_SHA): ' "$MERGE_LOG" 2>/dev/null || true)"
  fi
}

merge_status_for_pr() {
  local num="$1" status=""
  status="$(printf '%s\n' "$MERGE_RESULT" | sed -n "s/^PR #${num} MERGE_STATUS: \\([A-Za-z0-9._-]*\\).*$/\\1/p" | tail -n 1)"
  if [ -z "$status" ]; then
    status="$(grep -oE "PR #${num} MERGE_STATUS: [A-Za-z0-9._-]+" "$MERGE_LOG" 2>/dev/null | awk '{print $5}' | tail -n 1 || true)"
  fi
  printf '%s\n' "$status"
}

capture_pre_merge_shas() {
  local worker="" repo="" sha=""
  for worker in "${PASS_WORKERS[@]}"; do
    repo="${LOOP_ROOT}/${PROJECTS[$worker]}"
    sha=""
    if [ -d "$repo" ]; then
      sha="$(repo_origin_main_sha "$repo" || true)"
    fi
    PRE_MERGE_SHAS["$worker"]="$sha"
  done
}

merged_sha_for_pr() {
  local worker="$1" raw_status="${2:-}" num repo sha="" pre_sha="" post_sha=""
  num="$(worker_number "$worker")"
  sha="$(printf '%s\n' "$MERGE_RESULT" | sed -n "s/^PR #${num} MERGED_SHA: \\([A-Fa-f0-9]*\\).*$/\\1/p" | tail -n 1)"
  if [ -z "$sha" ]; then
    sha="$(grep -oE "PR #${num} MERGED_SHA: [A-Fa-f0-9]+" "$MERGE_LOG" 2>/dev/null | awk '{print $5}' | tail -n 1 || true)"
  fi
  if [ -n "$sha" ]; then
    printf '%s\n' "$sha"
    return 0
  fi
  case "$raw_status" in
    conflict|aborted|skipped_non_pass)
      return 0
      ;;
  esac
  repo="${LOOP_ROOT}/${PROJECTS[$worker]}"
  pre_sha="${PRE_MERGE_SHAS[$worker]:-}"
  if [ -n "$pre_sha" ] && [ -d "$repo" ]; then
    post_sha="$(repo_origin_main_sha "$repo" || true)"
    if [ -n "$post_sha" ] && [ "$post_sha" != "$pre_sha" ]; then
      log "Phase D: B30 git-log fallback accepted for ${worker} (origin/main changed ${pre_sha:0:7} -> ${post_sha:0:7})"
      printf '%s\n' "$post_sha"
      return 0
    fi
    log "Phase D: B30 git-log fallback REJECTED for ${worker} (origin/main unchanged at ${pre_sha:0:7})"
  fi
}

validate_args() {
  [ -n "$PROJECT_PREFIX" ] || die 1 "--project-prefix is required."
  [ -n "$MANIFESTS_DIR" ] || die 1 "--manifests-dir is required."
  [ -n "$TARGET_REPO_TEMPLATE" ] || die 1 "--target-repo-template is required."
  [ -n "$REVIEW_PROMPT_FILE" ] || die 1 "--review-prompt-file is required."
  [[ "$PROJECT_PREFIX" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die 1 "--project-prefix must match ^[a-z0-9][a-z0-9-]*$."
  [[ "$MANIFESTS_DIR" = /* ]] || die 1 "--manifests-dir must be an absolute path."
  [[ "$REVIEW_PROMPT_FILE" = /* ]] || die 1 "--review-prompt-file must be an absolute path."
  [ -d "$MANIFESTS_DIR" ] || die 1 "Manifests dir not found: $MANIFESTS_DIR"
  [ -r "$MANIFESTS_DIR" ] || die 1 "Manifests dir is not readable: $MANIFESTS_DIR"
  [ -f "$REVIEW_PROMPT_FILE" ] || die 1 "Review prompt file not found: $REVIEW_PROMPT_FILE"
  [ -r "$REVIEW_PROMPT_FILE" ] || die 1 "Review prompt file is not readable: $REVIEW_PROMPT_FILE"
  [[ "$TARGET_REPO_TEMPLATE" == */* ]] || die 1 "--target-repo-template must be OWNER/REPO-{N}."
  [[ "$TARGET_REPO_TEMPLATE" == *"{N}"* ]] || die 1 "--target-repo-template must include {N}."
  positive_integer "$MAX_PARALLEL" || die 1 "--max-parallel must be a positive integer."
  positive_integer "$MAX_WAIT_SEC" || die 1 "--max-wait-sec must be a positive integer."
  nonnegative_integer "$STAGGER_SEC" || die 1 "DISPATCH_BATCH_STAGGER_SEC must be a non-negative integer."
  case "$MODE" in gate|auto) ;; *) die 1 "--mode must be gate or auto." ;; esac
}

collect_manifests() {
  local path="" base="" worker="" project="" worker_num=""
  while IFS= read -r path; do
    base="${path##*/}"
    [[ "$base" =~ ^worker-(w[0-9]+)\.md$ ]] || die 1 "Unsupported manifest filename: $base"
    worker="${BASH_REMATCH[1]}"
    worker_num="$(worker_number "$worker")"
    project="${PROJECT_PREFIX}-${worker}"
    [ "${#project}" -le 25 ] || die 1 "B29: project slug '${project}' is too long. Max 25 chars because ccuser-${project} must fit POSIX 32."
    grep -Eq '(ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9-]{20,}|ANTHROPIC_API_KEY=[A-Za-z0-9-]{20,})' "$path" \
      && die 3 "B27 detection: PAT/secret leaked into manifest history candidate: $path"
    WORKERS+=("$worker")
    MANIFEST_PATHS["$worker"]="$path"
    PROJECTS["$worker"]="$project"
    TARGET_REPOS["$worker"]="${TARGET_REPO_TEMPLATE//\{N\}/$worker_num}"
    RESULT_STATUS["$worker"]="pending"
  done < <(find "$MANIFESTS_DIR" -maxdepth 1 -type f -name 'worker-w*.md' -print | sort -V)
  [ "${#WORKERS[@]}" -gt 0 ] || die 1 "No worker manifests found under $MANIFESTS_DIR (expected worker-w*.md)."
}

phase_a() {
  PHASES_RUN+=("A")
  for cmd in find grep jq sed sort stat; do need_cmd "$cmd"; done
  collect_manifests
  rm -f -- \
    /tmp/"${PROJECT_PREFIX}"-w*-manifest.md \
    /tmp/"${PROJECT_PREFIX}"-w*-merge-prompt.md \
    /tmp/"${PROJECT_PREFIX}"-w*-dispatch.log \
    /tmp/"${PROJECT_PREFIX}"-w*-review.log \
    /tmp/"${PROJECT_PREFIX}"-w*-merge.log \
    /tmp/"${PROJECT_PREFIX}"-w*-loop-f1.log \
    /tmp/"${PROJECT_PREFIX}"-batch-review.log \
    /tmp/"${PROJECT_PREFIX}"-batch-merge.log \
    /tmp/"${PROJECT_PREFIX}"-batch-review-prompt.md \
    /tmp/"${PROJECT_PREFIX}"-batch-merge-prompt.md
  [ -x "${SCRIPTS_DIR}/dispatch-pre.sh" ] || die 1 "Missing or not executable: ${SCRIPTS_DIR}/dispatch-pre.sh"
  [ -x "${SCRIPTS_DIR}/dispatch-review-merge-hardened.sh" ] || die 1 "Missing or not executable: ${SCRIPTS_DIR}/dispatch-review-merge-hardened.sh"
  [ -x "${SCRIPTS_DIR}/dispatch-loop-hardened.sh" ] || die 1 "Missing or not executable: ${SCRIPTS_DIR}/dispatch-loop-hardened.sh"
  [ -x "$CCC_TASK_SCRIPT" ] || die 1 "Missing or not executable: $CCC_TASK_SCRIPT"
  [ -r "$ANTHROPIC_KEY_FILE" ] || die 1 "Anthropic API key not readable: $ANTHROPIC_KEY_FILE"
  [ "$(stat -c '%a' "$ANTHROPIC_KEY_FILE")" = "600" ] || die 1 "Anthropic API key must have mode 600: $ANTHROPIC_KEY_FILE"
  if [ "$DRY_RUN" -eq 0 ]; then
    is_root || die 1 "Run as root for live batch dispatch, or add --dry-run."
    for cmd in claude gh git pgrep sudo; do need_cmd "$cmd"; done
    need_gh_auth
  fi
  log "Phase A (pre-flight): manifests=${#WORKERS[@]} mode=${MODE} max_parallel=${MAX_PARALLEL} api_key=ok"
}

wait_f1_batch() {
  local -n batch_workers_ref="$1"
  local -n batch_pids_ref="$2"
  local i=0 worker="" status=0 thread_list=()
  for i in "${!batch_pids_ref[@]}"; do
    worker="${batch_workers_ref[$i]}"
    set +e
    wait "${batch_pids_ref[$i]}"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
      THREAD_IDS["$worker"]="$(sed -n 's/.*Phase 7 (verify): thread_id=\([^,[:space:]]*\).*/\1/p' "${F1_LOGS[$worker]}" | tail -n 1)"
      [ -n "${THREAD_IDS[$worker]}" ] || THREAD_IDS["$worker"]="dry-run-thread-${worker}"
      RESULT_STATUS["$worker"]="launched"
      START_SECS["$worker"]="$SECONDS"
      thread_list+=("${THREAD_IDS[$worker]}")
    else
      RESULT_STATUS["$worker"]="dispatch_failed"
      add_error "F1 failed for ${worker} with status ${status}. Check ${F1_LOGS[$worker]}."
    fi
  done
  [ "${#thread_list[@]}" -gt 0 ] && log "Phase B (parallel dispatch): parallel_dispatched=${#thread_list[@]} thread_ids=[${thread_list[*]}]"
}

phase_b() {
  local worker="" pid="" launched=0
  local -a batch_workers=() batch_pids=()
  PHASES_RUN+=("B")
  for worker in "${WORKERS[@]}"; do
    F1_LOGS["$worker"]="/tmp/${PROJECTS[$worker]}-loop-f1.log"
    if ! ensure_target_repo "$worker"; then
      RESULT_STATUS["$worker"]="dispatch_failed"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      bash "${SCRIPTS_DIR}/dispatch-pre.sh" \
        --project "${PROJECTS[$worker]}" \
        --manifest-file "${MANIFEST_PATHS[$worker]}" \
        --target-repo "${TARGET_REPOS[$worker]}" \
        --worker-name "$worker" \
        --create-repo \
        --dry-run >"${F1_LOGS[$worker]}" 2>&1 &
    else
      GITHUB_TOKEN="$GITHUB_TOKEN" nohup bash "${SCRIPTS_DIR}/dispatch-pre.sh" \
        --project "${PROJECTS[$worker]}" \
        --manifest-file "${MANIFEST_PATHS[$worker]}" \
        --target-repo "${TARGET_REPOS[$worker]}" \
        --worker-name "$worker" \
        --create-repo >"${F1_LOGS[$worker]}" 2>&1 &
    fi
    pid=$!
    batch_workers+=("$worker")
    batch_pids+=("$pid")
    launched=$((launched + 1))
    [ "$DRY_RUN" -eq 1 ] || [ "$STAGGER_SEC" -eq 0 ] || sleep "$STAGGER_SEC"
    if [ "${#batch_workers[@]}" -ge "$MAX_PARALLEL" ]; then
      wait_f1_batch batch_workers batch_pids
      batch_workers=()
      batch_pids=()
    fi
  done
  [ "${#batch_workers[@]}" -eq 0 ] || wait_f1_batch batch_workers batch_pids
  log "Phase B (parallel dispatch): launched=${launched}"
}

phase_c() {
  local pending=0 worker="" project="" final_file="" elapsed=0
  PHASES_RUN+=("C")
  if [ "$DRY_RUN" -eq 1 ]; then
    for worker in "${WORKERS[@]}"; do
      [ "${RESULT_STATUS[$worker]}" = "launched" ] || continue
      FINAL_FILES["$worker"]="${CODEX_HEADLESS_ROOT}/${PROJECTS[$worker]}/${worker}/final-DRY-RUN.txt"
      PR_URLS["$worker"]="https://github.com/${TARGET_REPOS[$worker]}/pull/$(worker_number "$worker")"
      HEAD_SHAS["$worker"]="deadbee$(worker_number "$worker")"
      RESULT_STATUS["$worker"]="ready"
      REVIEWABLE_WORKERS+=("$worker")
    done
    log "Phase C (wait workers): DRY-RUN reviewable=${#REVIEWABLE_WORKERS[@]}"
    return 0
  fi
  while :; do
    pending=0
    for worker in "${WORKERS[@]}"; do
      [ "${RESULT_STATUS[$worker]}" = "launched" ] || continue
      project="${PROJECTS[$worker]}"
      elapsed=$((SECONDS - ${START_SECS[$worker]:-$SECONDS}))
      if worker_is_running "$project"; then
        if [ "$elapsed" -ge "$MAX_WAIT_SEC" ]; then
          RESULT_STATUS["$worker"]="timed_out"
          add_error "Worker ${worker} timed out after ${MAX_WAIT_SEC}s."
        else
          pending=$((pending + 1))
        fi
        continue
      fi
      final_file="$(latest_final_file "$project" "$worker" || true)"
      if [ -n "$final_file" ]; then
        FINAL_FILES["$worker"]="$final_file"
        if wait_for_pr_metadata "$worker"; then
          RESULT_STATUS["$worker"]="ready"
          REVIEWABLE_WORKERS+=("$worker")
        else
          RESULT_STATUS["$worker"]="no_pr"
          add_error "Worker ${worker} completed but no PR metadata was found for ${TARGET_REPOS[$worker]}."
        fi
      elif [ "$elapsed" -ge "$MAX_WAIT_SEC" ]; then
        RESULT_STATUS["$worker"]="crashed"
        add_error "Worker ${worker} produced no final output within ${MAX_WAIT_SEC}s."
      else
        pending=$((pending + 1))
      fi
    done
    [ "$pending" -eq 0 ] && break
    sleep 15
  done
  for worker in "${WORKERS[@]}"; do
    log "Phase C (wait workers): ${worker} status=${RESULT_STATUS[$worker]} final=${FINAL_FILES[$worker]:-none}"
  done
}

run_batch_merge() {
  local merge_cmd="" merge_status=0 worker="" raw_status="" sha="" api_key=""
  capture_pre_merge_shas
  write_merge_prompt
  MERGE_LOG="/tmp/${PROJECT_PREFIX}-batch-merge.log"
  : >"$MERGE_LOG"
  printf -v merge_cmd \
    'cd %q && claude -p --resume %q --permission-mode bypassPermissions --output-format json --verbose < %q' \
    "${LOOP_ROOT}/${BATCH_PROJECT}" "$REVIEW_SESSION_ID" "$MERGE_PROMPT_RENDERED"
  api_key="$(<"$ANTHROPIC_KEY_FILE")"
  nohup sudo -u "$BATCH_USER" env HOME="$BATCH_HOME" PATH="$BATCH_PATH" ANTHROPIC_API_KEY="$api_key" bash -c "$merge_cmd" >"$MERGE_LOG" 2>&1 &
  set +e
  wait "$!"
  merge_status=$?
  set -e
  load_merge_output
  [ -n "$MERGE_SESSION_ID" ] || MERGE_SESSION_ID="$REVIEW_SESSION_ID"
  for worker in "${REVIEWABLE_WORKERS[@]}"; do
    if [ "${VERDICTS[$worker]}" != "PASS" ]; then
      RESULT_STATUS["$worker"]="skipped"
      continue
    fi
    raw_status="$(merge_status_for_pr "$(worker_number "$worker")")"
    sha="$(merged_sha_for_pr "$worker" "$raw_status")"
    if [ -n "$sha" ]; then
      MERGED_SHAS["$worker"]="$sha"
      RESULT_STATUS["$worker"]="merged"
    elif [ -n "$raw_status" ] && [ "$raw_status" != "merged" ]; then
      RESULT_STATUS["$worker"]="$raw_status"
      add_error "PR #$(worker_number "$worker") reported ${raw_status} during batch merge."
    else
      RESULT_STATUS["$worker"]="merge_failed"
      add_error "B30 recovery could not determine MERGED_SHA for PR #$(worker_number "$worker")."
    fi
  done
  [ "$merge_status" -eq 0 ] || return 6
  return 0
}

phase_d() {
  local review_json="" review_status=0 worker="" is_error="" review_non_pass=0
  PHASES_RUN+=("D")
  [ "${#REVIEWABLE_WORKERS[@]}" -gt 0 ] || { FINAL_STATUS="crashed"; add_error "No reviewable workers reached batch review."; return 12; }
  if [ "$DRY_RUN" -eq 1 ]; then
    REVIEW_SESSION_ID="dry-run-session"
    REVIEW_COST_USD="0"
    MERGE_SESSION_ID="dry-run-session"
    MERGE_COST_USD="0"
    for worker in "${REVIEWABLE_WORKERS[@]}"; do
      VERDICTS["$worker"]="PASS"
      MERGED_SHAS["$worker"]="deadbee$(worker_number "$worker")"
      RESULT_STATUS["$worker"]="merged"
    done
    log "Phase D (batch CCC): DRY-RUN review+merge complete"
    return 0
  fi
  select_batch_anchor || { add_error "${ANCHOR_ERROR:-Batch anchor selection failed.}"; return 5; }
  [ -d "${LOOP_ROOT}/${BATCH_PROJECT}" ] || { add_error "Batch anchor repo not found: ${LOOP_ROOT}/${BATCH_PROJECT}."; return 5; }
  id "$BATCH_USER" >/dev/null 2>&1 || { add_error "Batch anchor user not found: ${BATCH_USER}."; return 5; }
  sudo -u "$BATCH_USER" env HOME="$BATCH_HOME" PATH="$BATCH_PATH" bash -lc 'command -v claude >/dev/null 2>&1' \
    || { add_error "claude CLI not available for batch anchor ${BATCH_USER}."; return 5; }
  sudo -u "$BATCH_USER" env HOME="$BATCH_HOME" PATH="$BATCH_PATH" gh auth status --hostname github.com >/dev/null 2>&1 \
    || { add_error "gh CLI is not authenticated for batch anchor ${BATCH_USER}."; return 5; }
  check_worker_claude_cli || return 5
  write_review_prompt
  REVIEW_LOG="/tmp/${PROJECT_PREFIX}-batch-review.log"
  : >"$REVIEW_LOG"
  nohup bash "$CCC_TASK_SCRIPT" \
    --project "$BATCH_PROJECT" \
    --task pre-merge-review \
    --prompt-file "$REVIEW_PROMPT_RENDERED" \
    --user "$BATCH_USER" \
    --output-format json >"$REVIEW_LOG" 2>&1 &
  set +e
  wait "$!"
  review_status=$?
  set -e
  review_json="$(json_object_from_log "$REVIEW_LOG")"
  [ "$review_status" -eq 0 ] || { add_error "Batch review failed with status ${review_status}. Check ${REVIEW_LOG}."; return 5; }
  [ -n "$review_json" ] || { add_error "Could not find JSON output in ${REVIEW_LOG}."; return 5; }
  is_error="$(printf '%s\n' "$review_json" | jq -r '.is_error // false')"
  [ "$is_error" = "false" ] || { add_error "Batch review returned is_error=true. Check ${REVIEW_LOG}."; return 5; }
  REVIEW_SESSION_ID="$(printf '%s\n' "$review_json" | jq -r '.session_id // empty')"
  REVIEW_COST_USD="$(printf '%s\n' "$review_json" | jq -r '(.total_cost_usd // empty) | tostring')"
  REVIEW_RESULT="$(printf '%s\n' "$review_json" | jq -r '.result // empty')"
  [ -n "$REVIEW_SESSION_ID" ] || { add_error "Batch review JSON did not include session_id."; return 5; }
  [ -n "$REVIEW_RESULT" ] || { add_error "Batch review JSON did not include result."; return 5; }
  set +e
  parse_review_verdicts
  review_non_pass=$?
  set -e
  if [ "$MODE" = "gate" ] && [ "$review_non_pass" -ne 0 ]; then
    for worker in "${REVIEWABLE_WORKERS[@]}"; do
      RESULT_STATUS["$worker"]="gated"
    done
    FINAL_STATUS="gated"
    return 10
  fi
  for worker in "${REVIEWABLE_WORKERS[@]}"; do
    [ "${VERDICTS[$worker]}" = "PASS" ] || RESULT_STATUS["$worker"]="skipped"
  done
  [ "${#PASS_WORKERS[@]}" -gt 0 ] || return 12
  run_batch_merge
}

phase_e() {
  local worker="" teardown_log=""
  PHASES_RUN+=("E")
  [ "$TEARDOWN" -eq 1 ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Phase E (teardown): DRY-RUN merged_workers=$(printf '%s ' "${PASS_WORKERS[@]}")"
    return 0
  fi
  [ -f "$TEARDOWN_SCRIPT" ] || { add_error "Teardown script not found: $TEARDOWN_SCRIPT"; return 7; }
  for worker in "${WORKERS[@]}"; do
    [ "${RESULT_STATUS[$worker]:-}" = "merged" ] || continue
    teardown_log="/tmp/${PROJECTS[$worker]}-teardown.log"
    if bash "$TEARDOWN_SCRIPT" --project "${PROJECTS[$worker]}" --force >"$teardown_log" 2>&1; then
      log "Phase E (teardown): ${worker} done"
    else
      add_error "Teardown failed for ${PROJECTS[$worker]}. Check ${teardown_log}."
    fi
  done
}

main() {
  local phase_d_status=0 phase_e_status=0 summary_status=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project-prefix|--manifests-dir|--target-repo-template|--review-prompt-file|--mode|--max-parallel|--max-wait-sec|--scripts-dir)
        need "$1" "${2:-}"
        case "$1" in
          --project-prefix) PROJECT_PREFIX="$2" ;;
          --manifests-dir) MANIFESTS_DIR="$2" ;;
          --target-repo-template) TARGET_REPO_TEMPLATE="$2" ;;
          --review-prompt-file) REVIEW_PROMPT_FILE="$2" ;;
          --mode) MODE="$2" ;;
          --max-parallel) MAX_PARALLEL="$2" ;;
          --max-wait-sec) MAX_WAIT_SEC="$2" ;;
          --scripts-dir) SCRIPTS_DIR="$2" ;;
        esac
        shift 2
        ;;
      --teardown) TEARDOWN=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --help|-h) SUMMARY_SUPPRESSED=1; usage; exit 0 ;;
      *) die 1 "Unknown argument: $1" ;;
    esac
  done
  validate_args
  phase_a
  phase_b
  phase_c
  set +e
  phase_d
  phase_d_status=$?
  set -e
  set +e
  phase_e
  phase_e_status=$?
  set -e
  [ "$phase_e_status" -eq 0 ] || [ "$phase_d_status" -ne 0 ] || phase_d_status="$phase_e_status"
  summary_status="$(current_summary_status)"
  case "$summary_status" in
    all_merged) exit 0 ;;
    gated) exit 10 ;;
    partial|crashed)
      [ "$phase_d_status" -gt 0 ] && exit "$phase_d_status"
      exit 12
      ;;
    *) exit "${phase_d_status:-1}" ;;
  esac
}

main "$@"
