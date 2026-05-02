#!/usr/bin/env bash
# ccc-headless-task.sh - Run one-shot Claude Code operator tasks without tmux.

set -euo pipefail

: "${DISPATCH_HOME:?DISPATCH_HOME must be set}"
ANTHROPIC_KEY_FILE="${CCC_HEADLESS_ANTHROPIC_KEY_FILE:-${DISPATCH_HOME}/.config/anthropic-api-key}"

SCRIPT_NAME="ccc-headless-task"
CURRENT_USER="$(id -un)"
BASE_DIR="${CCC_HEADLESS_BASE_DIR:-${DISPATCH_HOME}/repos}"
LOG_ROOT="${CCC_HEADLESS_LOG_ROOT:-${DISPATCH_HOME}/.ccc-headless}"
PROJECT=""
TASK=""
PROMPT_FILE=""
RUN_USER=""
OUTPUT_FORMAT="text"
DRY_RUN=0

TARGET_PATH_BASE="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
TARGET_HOME=""
PROJECT_DIR=""
LOG_DIR=""
RUN_ID=""
META_FILE=""
STDOUT_LOG=""
STDERR_LOG=""
STREAM_LOG=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/ccc-headless-task.sh --project PROJECT --task status|pre-merge-review|summary|custom --prompt-file PATH [--user USER] [--output-format text|json|stream-json] [--dry-run]

Run a one-shot Claude Code task in print mode from the trusted repo at
${DISPATCH_HOME}/repos/PROJECT (or $CCC_HEADLESS_BASE_DIR/PROJECT) and store
timestamped artifacts under ${DISPATCH_HOME}/.ccc-headless/PROJECT/TASK/
(or $CCC_HEADLESS_LOG_ROOT/PROJECT/TASK/).

Options:
  --project PROJECT         Project slug. Repository must exist at ${DISPATCH_HOME}/repos/PROJECT
  --task TASK               One of: status, pre-merge-review, summary, custom
  --prompt-file PATH        Prompt file to pass on stdin to Claude Code
  --user USER               Linux user to run Claude as (default: ccuser-PROJECT)
  --output-format FORMAT    One of: text, json, stream-json (default: text)
  --dry-run                 Print the resolved command and artifact paths without running Claude
  -h, --help                Show this help text

Notes:
  - This helper always uses Claude print mode (-p).
  - bypassPermissions is allowed only after the script verifies the trusted
    local repo path under the dispatcher-scoped repo root.
  - Prompt contents are never echoed by this wrapper.
EOF
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"

  command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
}

shell_join() {
  local args=()
  local argument=""

  for argument in "$@"; do
    args+=("$(printf '%q' "$argument")")
  done

  printf '%s' "${args[*]}"
}

lookup_user_home() {
  local user_name="$1"
  local passwd_entry=""

  passwd_entry="$(getent passwd "$user_name" || true)"
  [ -n "$passwd_entry" ] || return 1
  printf '%s\n' "$passwd_entry" | cut -d: -f6
}

ensure_nonempty_file() {
  local file_path="$1"
  local label="$2"

  [ -f "$file_path" ] || die "$label not found: $file_path"
  [ -r "$file_path" ] || die "$label is not readable: $file_path"
  [ -s "$file_path" ] || die "$label is empty: $file_path"
}

looks_like_sensitive_file() {
  local file_path="$1"

  case "$file_path" in
    */.claude/.credentials.json|*/.claude.json|*/.aws/credentials|*/.kube/config|*/.env|*/.env.*|*/id_rsa|*/id_ed25519|*.pem|*.key|*.p12|*.pfx)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_project_name() {
  case "$PROJECT" in
    ''|*[!A-Za-z0-9._-]*)
      die "Invalid --project value '$PROJECT'. Use only letters, numbers, dot, underscore, and dash."
      ;;
  esac
}

validate_task() {
  case "$TASK" in
    status|pre-merge-review|summary|custom)
      ;;
    *)
      die "Invalid --task value '$TASK'. Expected status, pre-merge-review, summary, or custom."
      ;;
  esac
}

validate_output_format() {
  case "$OUTPUT_FORMAT" in
    text|json|stream-json)
      ;;
    *)
      die "Invalid --output-format value '$OUTPUT_FORMAT'. Expected text, json, or stream-json."
      ;;
  esac
}

resolve_project_dir() {
  local expected_dir="${BASE_DIR}/${PROJECT}"
  local physical_dir=""

  [ -d "$expected_dir" ] || die "Trusted project repo not found: $expected_dir"
  [ -e "$expected_dir/.git" ] || die "Trusted project repo is missing .git metadata: $expected_dir"

  physical_dir="$(cd "$expected_dir" && pwd -P)"
  [ "$physical_dir" = "$expected_dir" ] || die "Refusing to use bypassPermissions outside the exact trusted repo path: $expected_dir"

  PROJECT_DIR="$expected_dir"
}

ensure_target_user_ready() {
  local user_path=""

  TARGET_HOME="$(lookup_user_home "$RUN_USER" || true)"
  [ -n "$TARGET_HOME" ] || die "User does not exist: $RUN_USER"

  if [ "$RUN_USER" != "$CURRENT_USER" ]; then
    require_command sudo
  fi

  user_path="${TARGET_HOME}/.npm-global/bin"
  TARGET_PATH="${user_path}:${DISPATCH_HOME}/.npm-global/bin:${TARGET_PATH_BASE}"
}

ensure_claude_available() {
  if [ "$RUN_USER" = "$CURRENT_USER" ]; then
    env "HOME=$TARGET_HOME" "PATH=$TARGET_PATH" bash -lc 'command -v claude >/dev/null 2>&1' || die "claude binary not found for user '$RUN_USER'"
    return
  fi

  sudo -u "$RUN_USER" env "HOME=$TARGET_HOME" "PATH=$TARGET_PATH" bash -lc 'command -v claude >/dev/null 2>&1' || die "claude binary not found for user '$RUN_USER'"
}

prepare_artifacts() {
  umask 077
  RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  LOG_DIR="${LOG_ROOT}/${PROJECT}/${TASK}"

  mkdir -p "$LOG_DIR"

  META_FILE="${LOG_DIR}/run-${RUN_ID}.meta"
  STDERR_LOG="${LOG_DIR}/stderr-${RUN_ID}.log"

  if [ "$OUTPUT_FORMAT" = "stream-json" ]; then
    STREAM_LOG="${LOG_DIR}/stream-${RUN_ID}.jsonl"
  else
    STDOUT_LOG="${LOG_DIR}/stdout-${RUN_ID}.log"
  fi
}

write_metadata() {
  local status="$1"
  local exit_code="${2:-}"
  local -a metadata_command=(claude -p --permission-mode bypassPermissions --output-format "$OUTPUT_FORMAT")

  if [ "$OUTPUT_FORMAT" = "stream-json" ]; then
    metadata_command+=(--verbose)
  fi

  {
    printf 'script=%s\n' "$SCRIPT_NAME"
    printf 'status=%s\n' "$status"
    printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'project=%s\n' "$PROJECT"
    printf 'task=%s\n' "$TASK"
    printf 'user=%s\n' "$RUN_USER"
    printf 'output_format=%s\n' "$OUTPUT_FORMAT"
    printf 'project_dir=%s\n' "$PROJECT_DIR"
    printf 'prompt_file=%s\n' "$PROMPT_FILE"
    printf 'stderr_log=%s\n' "$STDERR_LOG"
    if [ -n "$STDOUT_LOG" ]; then
      printf 'stdout_log=%s\n' "$STDOUT_LOG"
    fi
    if [ -n "$STREAM_LOG" ]; then
      printf 'stream_log=%s\n' "$STREAM_LOG"
    fi
    if [ -n "$exit_code" ]; then
      printf 'exit_code=%s\n' "$exit_code"
    fi
    printf 'command=%s\n' "$(shell_join "${metadata_command[@]}")"
  } >"$META_FILE"
}

run_claude() {
  # shellcheck disable=SC2016
  local command_text='cd -- "$1"; shift; exec claude "$@"'
  local -a claude_args=(-p --permission-mode bypassPermissions --output-format "$OUTPUT_FORMAT")
  local api_key=""

  if [ "$OUTPUT_FORMAT" = "stream-json" ]; then
    claude_args+=(--verbose)
  fi

  api_key="$(<"$ANTHROPIC_KEY_FILE")"

  if [ "$RUN_USER" = "$CURRENT_USER" ]; then
    env "HOME=$TARGET_HOME" "PATH=$TARGET_PATH" "ANTHROPIC_API_KEY=$api_key" bash -lc "$command_text" bash "$PROJECT_DIR" "${claude_args[@]}"
    return
  fi

  sudo -u "$RUN_USER" env "HOME=$TARGET_HOME" "PATH=$TARGET_PATH" "ANTHROPIC_API_KEY=$api_key" bash -lc "$command_text" bash "$PROJECT_DIR" "${claude_args[@]}"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)
        [ "$#" -ge 2 ] || die "Option '--project' requires a value."
        PROJECT="$2"
        shift 2
        ;;
      --task)
        [ "$#" -ge 2 ] || die "Option '--task' requires a value."
        TASK="$2"
        shift 2
        ;;
      --prompt-file)
        [ "$#" -ge 2 ] || die "Option '--prompt-file' requires a value."
        PROMPT_FILE="$2"
        shift 2
        ;;
      --user)
        [ "$#" -ge 2 ] || die "Option '--user' requires a value."
        RUN_USER="$2"
        shift 2
        ;;
      --output-format)
        [ "$#" -ge 2 ] || die "Option '--output-format' requires a value."
        OUTPUT_FORMAT="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

parse_args "$@"

[ -n "$PROJECT" ] || die "Missing required option: --project"
[ -n "$TASK" ] || die "Missing required option: --task"
[ -n "$PROMPT_FILE" ] || die "Missing required option: --prompt-file"

validate_project_name
validate_task
validate_output_format

[ -r "$ANTHROPIC_KEY_FILE" ] || die "Anthropic API key not readable: $ANTHROPIC_KEY_FILE"
[ "$(stat -c '%a' "$ANTHROPIC_KEY_FILE")" = "600" ] || die "Anthropic API key must have mode 600: $ANTHROPIC_KEY_FILE"

if [ -z "$RUN_USER" ]; then
  RUN_USER="ccuser-${PROJECT}"
fi

ensure_nonempty_file "$PROMPT_FILE" "Prompt file"
looks_like_sensitive_file "$PROMPT_FILE" && die "Refusing to use a likely credential or secret file as the prompt source: $PROMPT_FILE"

resolve_project_dir
ensure_target_user_ready
ensure_claude_available

if [ "$DRY_RUN" -eq 1 ]; then
  RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  LOG_DIR="${LOG_ROOT}/${PROJECT}/${TASK}"
  STDERR_LOG="${LOG_DIR}/stderr-${RUN_ID}.log"
  if [ "$OUTPUT_FORMAT" = "stream-json" ]; then
    STREAM_LOG="${LOG_DIR}/stream-${RUN_ID}.jsonl"
  else
    STDOUT_LOG="${LOG_DIR}/stdout-${RUN_ID}.log"
  fi

  log "DRY-RUN: trusted project repo: $PROJECT_DIR"
  log "DRY-RUN: run user: $RUN_USER"
  log "DRY-RUN: output format: $OUTPUT_FORMAT"
  log "DRY-RUN: prompt file: $PROMPT_FILE"
  if [ -n "$STDOUT_LOG" ]; then
    log "DRY-RUN: stdout log: $STDOUT_LOG"
  fi
  if [ -n "$STREAM_LOG" ]; then
    log "DRY-RUN: stream log: $STREAM_LOG"
  fi
  log "DRY-RUN: stderr log: $STDERR_LOG"
  log "DRY-RUN: meta file: ${LOG_DIR}/run-${RUN_ID}.meta"
  dry_run_command=(claude -p --permission-mode bypassPermissions --output-format "$OUTPUT_FORMAT")
  if [ "$OUTPUT_FORMAT" = "stream-json" ]; then
    dry_run_command+=(--verbose)
  fi
  log "DRY-RUN: command: $(shell_join "${dry_run_command[@]}")"
  exit 0
fi

prepare_artifacts
write_metadata "running"

log "Running headless CCC task '$TASK' for project '$PROJECT' from $PROJECT_DIR"
log "Artifacts: $LOG_DIR"

claude_status=0

if [ "$OUTPUT_FORMAT" = "stream-json" ]; then
  set +e
  run_claude <"$PROMPT_FILE" 2> >(tee "$STDERR_LOG" >&2) | tee "$STREAM_LOG"
  pipeline_status=("${PIPESTATUS[@]}")
  claude_status="${pipeline_status[0]}"
  set -e
else
  set +e
  run_claude <"$PROMPT_FILE" > >(tee "$STDOUT_LOG") 2> >(tee "$STDERR_LOG" >&2)
  claude_status=$?
  set -e
fi

if [ "$claude_status" -eq 0 ]; then
  write_metadata "completed" "$claude_status"
  log "Task completed successfully."
else
  write_metadata "failed" "$claude_status"
  warn "Task failed with exit code $claude_status. Artifacts preserved in $LOG_DIR"
fi

exit "$claude_status"
