#!/bin/bash
# dispatch-worker.sh — create worker worktree, spawn Codex, deliver manifest

set -euo pipefail

: "${DISPATCH_HOME:?DISPATCH_HOME must be set}"

SCRIPT_NAME="dispatch-worker"
TARGET_PATH_BASE="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
DISPATCH_NPM_GLOBAL_BIN="${DISPATCH_WORKER_DISPATCH_NPM_GLOBAL_BIN:-${DISPATCH_HOME}/.npm-global/bin}"
REGISTRY_DIR="${DISPATCH_WORKER_REGISTRY_DIR:-${DISPATCH_HOME}/registries}"
CODEX_HEADLESS_ROOT="${DISPATCH_WORKER_CODEX_HEADLESS_ROOT:-${DISPATCH_HOME}/.codex-headless}"
CODEX_SESSION_ROOT="${DISPATCH_WORKER_CODEX_SESSION_ROOT:-${DISPATCH_HOME}/.codex/sessions}"
CODEX_SESSIONS_REGISTRY="${DISPATCH_WORKER_CODEX_SESSIONS_REGISTRY:-${REGISTRY_DIR}/codex-sessions.jsonl}"
CODEX_LATEST_SESSION_FILE="${DISPATCH_WORKER_CODEX_LATEST_SESSION_FILE:-${REGISTRY_DIR}/codex-latest-session.json}"

PROJECT=""
WORKER_NAME=""
MANIFEST_FILE=""
MODEL="gpt-5.4"
EFFORT="xhigh"
BACKEND="tui"
RUN_USER=""
RUN_GROUP=""
RUN_HOME=""
CODEX_API_KEY_FILE="${CODEX_API_KEY_FILE:-}"
REPO_ROOT=""
DRY_RUN=0
CLEANUP_ON_FAILURE=1

TMUX_SESSION=""
BRANCH_NAME=""
WORKTREE_PATH=""
WORKTREE_PARENT=""
SPAWN_SCRIPT=""
MANIFEST_MARKER=""
SPAWN_OUTPUT=""
CODEX_SESSION_ID=""
HEADLESS_OUTPUT_DIR=""
HEADLESS_LOG_FILE=""
HEADLESS_FINAL_FILE=""
HEADLESS_EVENTS_FILE=""
HEADLESS_RUNNER=""

WORKTREE_CREATED=0
BRANCH_CREATED=0
SESSION_CREATED=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/dispatch-worker.sh --project PROJECT --worker-name NAME --manifest-file FILE [--model MODEL] [--effort EFFORT] [--user USER] [--backend tui|headless] [--codex-api-key-file FILE] [--dry-run]

Required:
  --project PROJECT         Project name used in branch/session/path naming
  --worker-name NAME        Worker name suffix
  --manifest-file FILE      Manifest file to deliver into the Codex session

Optional:
  --model MODEL             Codex model (default: gpt-5.4)
  --effort EFFORT           Reasoning effort (default: xhigh)
  --user USER               Run Codex and own the worktree as USER
  --backend BACKEND         Worker backend: tui or headless (default: tui)
  --codex-api-key-file FILE Run codex login --with-api-key from this secret file before dispatch
  --headless                Alias for --backend headless
  --dry-run                 Show planned actions without changing git or tmux state
  --help                    Show this help

Naming:
  tmux session: worker-{project}-{worker-name}
  git branch:   worker/{project}-{worker-name}
  worktree:     <repo-root>/.letta/worktrees/worker-{project}-{worker-name}
EOF
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

warn() {
  printf '[%s] WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

show_command() {
  local rendered="" arg

  for arg in "$@"; do
    rendered+=" $(printf '%q' "$arg")"
  done

  printf '%s\n' "${rendered# }"
}

json_escape() {
  local value="$1"

  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1. Install it and retry."
}

run_readonly_cmd() {
  local description="$1"
  shift

  if ! "$@"; then
    die "$description failed while running '$(show_command "$@")'. Check repository access and retry."
  fi
}

capture_readonly_cmd() {
  local __var_name="$1"
  local description="$2"
  local output=""
  local status=0
  shift 2

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    die "$description failed while running '$(show_command "$@")': $output"
  fi

  printf -v "$__var_name" '%s' "$output"
}

run_cmd() {
  local description="$1"
  shift

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: $description"
    printf '  %s\n' "$(show_command "$@")"
    return 0
  fi

  if ! "$@"; then
    die "$description failed while running '$(show_command "$@")'. Review the command output above and retry."
  fi
}

pause() {
  local seconds="$1"

  if ! sleep "$seconds"; then
    die "sleep $seconds failed unexpectedly. Retry the dispatch."
  fi
}

require_option_value() {
  local option_name="$1"
  local option_value="${2:-}"

  [ -n "$option_value" ] || die "Option '$option_name' requires a value. Re-run the command with '$option_name VALUE'."
}

trim_leading_whitespace() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  printf '%s\n' "$value"
}

extract_field() {
  local label="$1"
  local text="$2"
  local line
  local value

  while IFS= read -r line; do
    case "$line" in
      "$label":*)
        value="${line#"$label":}"
        value="$(trim_leading_whitespace "$value")"
        printf '%s\n' "$value"
        return 0
        ;;
    esac
  done <<<"$text"

  printf '\n'
}

extract_uuid() {
  local text="$1"

  if [[ "$text" =~ ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  printf '\n'
}

ensure_file_is_readable_and_nonempty() {
  local file_path="$1"
  local label="$2"

  [ -f "$file_path" ] || die "$label not found: $file_path. Provide an existing file and retry."
  [ -r "$file_path" ] || die "$label is not readable: $file_path. Check file permissions and retry."
  [ -s "$file_path" ] || die "$label is empty: $file_path. Add content before dispatching."
}

ensure_secret_file() {
  local file_path="$1"
  local label="$2"
  local mode=""
  local group_digit=""
  local other_digit=""

  [ -f "$file_path" ] || die "$label not found: $file_path"
  [ -r "$file_path" ] || die "$label is not readable: $file_path"

  if command -v stat >/dev/null 2>&1; then
    mode="$(stat -c '%a' "$file_path" 2>/dev/null || true)"
    if [[ "$mode" =~ ^[0-7]+$ ]] && [ "${#mode}" -ge 3 ]; then
      mode="${mode: -3}"
      group_digit="${mode:1:1}"
      other_digit="${mode:2:1}"
      if [[ "$group_digit" != "0" || "$other_digit" != "0" ]]; then
        die "$label must not be readable by group/other: $file_path (chmod 600 or 400)"
      fi
    fi
  fi
}

ensure_directory_access() {
  local directory_path="$1"
  local label="$2"

  [ -d "$directory_path" ] || die "$label '$directory_path' does not exist. Create it or correct the path before retrying."
  [ -r "$directory_path" ] || die "Cannot read $label '$directory_path'. Check directory permissions and retry."
  [ -x "$directory_path" ] || die "Cannot enter $label '$directory_path'. Check directory permissions and retry."
  [ -w "$directory_path" ] || die "Cannot write to $label '$directory_path'. Check ownership or run with sufficient permissions."
}

ensure_directory_exists() {
  local directory_path="$1"
  local label="$2"

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -d "$directory_path" ]; then
      log "DRY-RUN: $label already exists: $directory_path"
    else
      log "DRY-RUN: would create $label: $directory_path"
    fi
    return 0
  fi

  mkdir -p -- "$directory_path"
}

directory_has_entries() {
  local directory_path="$1"
  local dotglob_was_set=0
  local nullglob_was_set=0
  local -a entries=()

  shopt -q dotglob && dotglob_was_set=1
  shopt -q nullglob && nullglob_was_set=1
  shopt -s dotglob nullglob
  entries=("$directory_path"/*)
  if [ "$dotglob_was_set" -eq 0 ]; then
    shopt -u dotglob
  fi
  if [ "$nullglob_was_set" -eq 0 ]; then
    shopt -u nullglob
  fi

  [ "${#entries[@]}" -gt 0 ]
}

validate_run_user() {
  local user_name="$1"
  local passwd_entry=""

  [ -n "$user_name" ] || return 0

  if ! id "$user_name" >/dev/null 2>&1; then
    die "User '$user_name' does not exist. Create the user first or omit --user."
  fi

  if ! RUN_GROUP="$(id -gn "$user_name" 2>/dev/null)"; then
    die "User '$user_name' does not exist. Create the user first or omit --user."
  fi

  passwd_entry="$(getent passwd "$user_name" || true)"
  RUN_HOME="$(printf '%s\n' "$passwd_entry" | cut -d: -f6)"
  [ -n "$RUN_HOME" ] || die "Could not determine home directory for user '$user_name'. Check passwd entry and retry."
}

tmux_session_exists() {
  tmux has-session -t "$1" >/dev/null 2>&1
}

capture_tmux_pane() {
  local session_name="$1"
  local __var_name="$2"
  local pane_output=""

  capture_readonly_cmd pane_output "capture tmux pane for session '$session_name'" tmux capture-pane -t "$session_name" -p
  printf -v "$__var_name" '%s' "$pane_output"
}

registered_worktree_for_branch() {
  local branch_name="$1"
  local branch_ref="refs/heads/$branch_name"
  local listing=""
  local line
  local current_path=""

  capture_readonly_cmd listing "inspect registered git worktrees" git worktree list --porcelain

  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        current_path="${line#worktree }"
        ;;
      branch\ *)
        if [ "${line#branch }" = "$branch_ref" ]; then
          printf '%s\n' "$current_path"
          return 0
        fi
        ;;
    esac
  done <<<"$listing"

  printf '\n'
}

registered_branch_for_worktree() {
  local worktree_path="$1"
  local listing=""
  local line
  local current_path=""

  capture_readonly_cmd listing "inspect registered git worktrees" git worktree list --porcelain

  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        current_path="${line#worktree }"
        ;;
      branch\ *)
        if [ "$current_path" = "$worktree_path" ]; then
          printf '%s\n' "${line#branch }"
          return 0
        fi
        ;;
      detached)
        if [ "$current_path" = "$worktree_path" ]; then
          printf 'detached\n'
          return 0
        fi
        ;;
    esac
  done <<<"$listing"

  printf '\n'
}

has_origin_remote() {
  git remote get-url origin >/dev/null 2>&1
}

remote_branch_exists() {
  local branch_name="$1"
  local output=""
  local status=0

  set +e
  output="$(git ls-remote --exit-code --heads origin "refs/heads/$branch_name" 2>&1)"
  status=$?
  set -e

  case "$status" in
    0)
      return 0
      ;;
    2)
      return 1
      ;;
    *)
      warn "Could not verify whether origin/$branch_name already exists: $output. Proceeding with local refs only."
      return 1
      ;;
  esac
}

ensure_worktree() {
  local existing_path_for_branch=""
  local existing_branch_for_path=""

  # Edge cases:
  # - Re-runs reuse the exact worktree/session pair instead of failing.
  # - If the branch is already attached elsewhere, the script stops with a fix-up hint
  #   instead of creating a second checkout with the same name.
  # - If origin already has the branch, a local tracking branch is created to avoid divergence.
  existing_path_for_branch="$(registered_worktree_for_branch "$BRANCH_NAME")"
  existing_branch_for_path="$(registered_branch_for_worktree "$WORKTREE_PATH")"

  if [ -n "$existing_path_for_branch" ]; then
    if [ "$existing_path_for_branch" != "$WORKTREE_PATH" ]; then
      if [ ! -d "$existing_path_for_branch" ]; then
        die "Branch '$BRANCH_NAME' is still registered to missing worktree '$existing_path_for_branch'. Run 'git worktree prune' and retry."
      fi
      die "Branch '$BRANCH_NAME' is already checked out at '$existing_path_for_branch'. Reuse that worktree or remove it before dispatching again."
    fi
    log "Reusing existing worktree: $WORKTREE_PATH"
    return 0
  fi

  if [ -n "$existing_branch_for_path" ]; then
    if [ "$existing_branch_for_path" != "refs/heads/$BRANCH_NAME" ]; then
      die "Worktree path '$WORKTREE_PATH' is already registered with '$existing_branch_for_path'. Remove the conflicting worktree or choose a different worker name."
    fi
    log "Reusing existing worktree: $WORKTREE_PATH"
    return 0
  fi

  if [ -e "$WORKTREE_PATH" ] && [ ! -d "$WORKTREE_PATH" ]; then
    die "Path '$WORKTREE_PATH' already exists and is not a directory. Remove the file or choose a different worker name."
  fi

  if [ -d "$WORKTREE_PATH" ]; then
    ensure_directory_access "$WORKTREE_PATH" "worktree directory"
    if directory_has_entries "$WORKTREE_PATH"; then
      die "Path '$WORKTREE_PATH' already exists and is not an empty directory or registered worktree. Clean it up before retrying."
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ] && [ ! -d "$WORKTREE_PARENT" ]; then
    log "DRY-RUN: worktree parent directory would be created before git worktree add"
  else
    ensure_directory_access "$WORKTREE_PARENT" "worktree parent directory"
  fi

  if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    log "Branch already exists locally; attaching worktree '$WORKTREE_PATH'"
    run_cmd "attach worktree '$WORKTREE_PATH' to local branch '$BRANCH_NAME'" git worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
    if [ "$DRY_RUN" -eq 0 ]; then
      WORKTREE_CREATED=1
    fi
    return 0
  fi

  if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH_NAME"; then
    log "Remote branch already exists; creating tracking worktree '$WORKTREE_PATH'"
    run_cmd "create worktree '$WORKTREE_PATH' from remote branch 'origin/$BRANCH_NAME'" git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "origin/$BRANCH_NAME"
    if [ "$DRY_RUN" -eq 0 ]; then
      WORKTREE_CREATED=1
      BRANCH_CREATED=1
      run_cmd "set upstream for '$BRANCH_NAME' to 'origin/$BRANCH_NAME'" git -C "$WORKTREE_PATH" branch --set-upstream-to "origin/$BRANCH_NAME" "$BRANCH_NAME"
    fi
    return 0
  fi

  if has_origin_remote && remote_branch_exists "$BRANCH_NAME"; then
    run_cmd "fetch remote branch 'origin/$BRANCH_NAME'" git fetch origin "refs/heads/$BRANCH_NAME:refs/remotes/origin/$BRANCH_NAME"
    run_cmd "create worktree '$WORKTREE_PATH' from fetched remote branch 'origin/$BRANCH_NAME'" git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "origin/$BRANCH_NAME"
    if [ "$DRY_RUN" -eq 0 ]; then
      WORKTREE_CREATED=1
      BRANCH_CREATED=1
      run_cmd "set upstream for '$BRANCH_NAME' to 'origin/$BRANCH_NAME'" git -C "$WORKTREE_PATH" branch --set-upstream-to "origin/$BRANCH_NAME" "$BRANCH_NAME"
    fi
    return 0
  fi

  log "Creating worktree '$WORKTREE_PATH' on new branch '$BRANCH_NAME'"
  run_cmd "create worktree '$WORKTREE_PATH' on new branch '$BRANCH_NAME'" git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH"
  if [ "$DRY_RUN" -eq 0 ]; then
    WORKTREE_CREATED=1
    BRANCH_CREATED=1
  fi
}

global_safe_directory_exists() {
  local output=""
  local status=0
  local line

  set +e
  output="$(git config --global --get-all safe.directory 2>/dev/null)"
  status=$?
  set -e

  if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    die "Failed to read global git safe.directory settings. Check access to your global git config and retry."
  fi

  while IFS= read -r line; do
    if [ "$line" = "$WORKTREE_PATH" ]; then
      return 0
    fi
  done <<<"$output"

  return 1
}

configure_worktree() {
  local manifest_relative_path="manifests/worker-${WORKER_NAME}.md"
  local manifest_target="$WORKTREE_PATH/$manifest_relative_path"
  local manifest_commit_subject="${MANIFEST_FILE##*/}"
  local worktree_git_dir=""
  local common_git_dir=""
  local gitdir_pointer=""
  local manifest_content=""

  manifest_commit_subject="${manifest_commit_subject%.md}"

  # Edge cases:
  # - The target user is validated before chown/sudo to avoid partial setup.
  # - Re-runs only create a manifest commit when the per-worker manifest content changes.
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -n "$RUN_USER" ]; then
      log "DRY-RUN: would change ownership of '$WORKTREE_PATH' and git metadata to '$RUN_USER:$RUN_GROUP'"
    fi
    if global_safe_directory_exists; then
      log "DRY-RUN: '$WORKTREE_PATH' is already listed in global git safe.directory"
    else
      log "DRY-RUN: would add '$WORKTREE_PATH' to global git safe.directory"
    fi
    log "DRY-RUN: would configure git identity in '$WORKTREE_PATH'"
    log "DRY-RUN: would copy '$MANIFEST_FILE' to '$manifest_target' and commit it if the content changed"
    return 0
  fi

  if [ -n "$RUN_USER" ]; then
    if ! worktree_git_dir="$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir 2>/dev/null)"; then
      if ! gitdir_pointer="$(<"$WORKTREE_PATH/.git")"; then
        die "Failed to read '$WORKTREE_PATH/.git'. Check worktree permissions and retry."
      fi
      case "$gitdir_pointer" in
        gitdir:\ *)
          worktree_git_dir="${gitdir_pointer#gitdir: }"
          ;;
        *)
          worktree_git_dir="$WORKTREE_PATH/.git"
          ;;
      esac
      if [[ "$worktree_git_dir" != /* ]]; then
        worktree_git_dir="$WORKTREE_PATH/$worktree_git_dir"
      fi
    fi

    run_cmd "change ownership of worktree '$WORKTREE_PATH' to '$RUN_USER:$RUN_GROUP'" chown -R "$RUN_USER:$RUN_GROUP" "$WORKTREE_PATH"
    if [ -e "$worktree_git_dir" ]; then
      run_cmd "change ownership of git metadata '$worktree_git_dir' to '$RUN_USER:$RUN_GROUP'" chown -R "$RUN_USER:$RUN_GROUP" "$worktree_git_dir"
    fi
    if common_git_dir="$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir 2>/dev/null)"; then
      if [[ "$common_git_dir" != /* ]]; then
        common_git_dir="$(cd "$worktree_git_dir" && cd "$common_git_dir" && pwd)"
      fi
      if [ -d "$common_git_dir" ]; then
        run_cmd "change ownership of common git metadata '$common_git_dir' to '$RUN_USER:$RUN_GROUP'" chown -R "$RUN_USER:$RUN_GROUP" "$common_git_dir"
      fi
    fi
  fi

  git config --global --add safe.directory "$REPO_ROOT" >/dev/null 2>&1 || true
  if global_safe_directory_exists; then
    log "Global git safe.directory already includes '$WORKTREE_PATH'"
  else
    run_cmd "add '$WORKTREE_PATH' to global git safe.directory" git config --global --add safe.directory "$WORKTREE_PATH"
  fi

  run_cmd "set git user.name in '$WORKTREE_PATH'" git -C "$WORKTREE_PATH" config user.name "Comp Worker"
  run_cmd "set git user.email in '$WORKTREE_PATH'" git -C "$WORKTREE_PATH" config user.email "comp@fractals-ai.com"

  run_cmd "create manifest directory in '$WORKTREE_PATH'" mkdir -p -- "$WORKTREE_PATH/manifests"
  if ! cp -- "$MANIFEST_FILE" "$manifest_target"; then
    die "Failed to copy manifest to '$manifest_target'. Check worktree permissions and retry."
  fi
  if [ -n "$RUN_USER" ]; then
    run_cmd "change ownership of manifest directory in '$WORKTREE_PATH'" chown -R "$RUN_USER:$RUN_GROUP" "$WORKTREE_PATH/manifests"
  fi

  run_cmd "stage $manifest_relative_path in '$WORKTREE_PATH'" git -C "$WORKTREE_PATH" add -- "$manifest_relative_path"
  if git -C "$WORKTREE_PATH" diff --cached --quiet -- "$manifest_relative_path"; then
    log "$manifest_relative_path already matches '$MANIFEST_FILE'; no commit created"
    return 0
  fi

  capture_readonly_cmd manifest_content "read manifest file '$MANIFEST_FILE'" cat "$MANIFEST_FILE"
  [ -n "$manifest_content" ] || die "Manifest file became empty before commit: $MANIFEST_FILE. Restore the file and retry."
  run_cmd "commit $manifest_relative_path in '$WORKTREE_PATH'" git -C "$WORKTREE_PATH" commit -m "manifest: $manifest_commit_subject" --no-verify
  if [ -n "$RUN_USER" ]; then
    if [ -e "$worktree_git_dir" ]; then
      run_cmd "restore ownership of git metadata '$worktree_git_dir' to '$RUN_USER:$RUN_GROUP'" chown -R "$RUN_USER:$RUN_GROUP" "$worktree_git_dir"
    fi
    if [ -n "$common_git_dir" ] && [ -d "$common_git_dir" ]; then
      run_cmd "restore ownership of common git metadata '$common_git_dir' to '$RUN_USER:$RUN_GROUP'" chown -R "$RUN_USER:$RUN_GROUP" "$common_git_dir"
    fi
  fi
  log "$manifest_relative_path committed to worktree"
}

configure_codex_api_key_auth() {
  local current_user=""
  local target_home="${HOME:-${DISPATCH_HOME}}"
  local target_path="${target_home}/.npm-global/bin:${DISPATCH_NPM_GLOBAL_BIN}:${TARGET_PATH_BASE}"

  [ -n "$CODEX_API_KEY_FILE" ] || return 0
  ensure_secret_file "$CODEX_API_KEY_FILE" "Codex API key file"

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -n "$RUN_USER" ]; then
      log "DRY-RUN: would run codex login --with-api-key for '$RUN_USER' using the configured secret file"
    else
      log "DRY-RUN: would run codex login --with-api-key for the current user using the configured secret file"
    fi
    return 0
  fi

  require_cmd codex
  current_user="$(id -un)"

  if [ -n "$RUN_USER" ]; then
    target_home="$RUN_HOME"
    target_path="${RUN_HOME}/.npm-global/bin:${DISPATCH_NPM_GLOBAL_BIN}:${TARGET_PATH_BASE}"
    if [ "$RUN_USER" != "$current_user" ]; then
      require_cmd sudo
      if ! { sudo -u "$RUN_USER" env "HOME=$target_home" "PATH=$target_path" \
          codex login --with-api-key >/dev/null; } < "$CODEX_API_KEY_FILE"; then
        die "codex login --with-api-key failed for '$RUN_USER'"
      fi
      log "Configured Codex API-key login for '$RUN_USER'"
      return 0
    fi
  fi

  if ! env "HOME=$target_home" "PATH=$target_path" \
      codex login --with-api-key < "$CODEX_API_KEY_FILE" >/dev/null; then
    die "codex login --with-api-key failed for the current user"
  fi
  log "Configured Codex API-key login for the current user"
}

save_headless_session_record() {
  local session_id="$1"
  local status="$2"
  local record=""

  [ -n "$session_id" ] || session_id="UNKNOWN"

  printf -v record '{"tmux_session": "%s", "codex_session_id": "%s", "backend": "headless", "model": "%s", "reasoning_effort": "%s", "project": "%s", "worker": "%s", "project_dir": "%s", "manifest": "%s", "log_file": "%s", "final_file": "%s", "events_file": "%s", "created": "%s", "status": "%s", "resumed": false}' \
    "$(json_escape "$TMUX_SESSION")" \
    "$(json_escape "$session_id")" \
    "$(json_escape "$MODEL")" \
    "$(json_escape "$EFFORT")" \
    "$(json_escape "$PROJECT")" \
    "$(json_escape "$WORKER_NAME")" \
    "$(json_escape "$WORKTREE_PATH")" \
    "$(json_escape "$WORKTREE_PATH/manifests/worker-${WORKER_NAME}.md")" \
    "$(json_escape "$HEADLESS_LOG_FILE")" \
    "$(json_escape "$HEADLESS_FINAL_FILE")" \
    "$(json_escape "$HEADLESS_EVENTS_FILE")" \
    "$(date -Iseconds)" \
    "$(json_escape "$status")"

  if [ ! -d "$REGISTRY_DIR" ]; then
    mkdir -p -- "$REGISTRY_DIR" || die "Failed to create registry directory: $REGISTRY_DIR"
  fi

  printf '%s\n' "$record" >> "$CODEX_SESSIONS_REGISTRY"
  printf '%s\n' "$record" > "$CODEX_LATEST_SESSION_FILE"
}

extract_headless_session_id() {
  local session_id=""
  local rollout_path=""

  if [ -n "$HEADLESS_EVENTS_FILE" ] && [ -f "$HEADLESS_EVENTS_FILE" ]; then
    if command -v jq >/dev/null 2>&1; then
      session_id="$(jq -r 'select(.type == "thread.started") | .thread_id // empty' "$HEADLESS_EVENTS_FILE" 2>/dev/null | tail -n 1)"
      if [ -n "$session_id" ]; then
        printf '%s\n' "$session_id"
        return 0
      fi
    fi

    session_id="$(sed -n 's/.*"thread_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HEADLESS_EVENTS_FILE" 2>/dev/null | tail -n 1)"
    if [ -n "$session_id" ]; then
      printf '%s\n' "$session_id"
      return 0
    fi

    session_id="$(extract_uuid "$(<"$HEADLESS_EVENTS_FILE")")"
    if [ -n "$session_id" ]; then
      printf '%s\n' "$session_id"
      return 0
    fi
  fi

  if [ -n "$HEADLESS_LOG_FILE" ] && [ -f "$HEADLESS_LOG_FILE" ]; then
    session_id="$(sed -n 's/^session id:[[:space:]]*//p' "$HEADLESS_LOG_FILE" 2>/dev/null | tail -n 1)"
    if [ -n "$session_id" ]; then
      printf '%s\n' "$session_id"
      return 0
    fi

    session_id="$(extract_uuid "$(<"$HEADLESS_LOG_FILE")")"
    if [ -n "$session_id" ]; then
      printf '%s\n' "$session_id"
      return 0
    fi
  fi

  rollout_path="$(latest_rollout_after_marker "$MANIFEST_MARKER")"
  session_id="$(extract_uuid "$rollout_path")"
  printf '%s\n' "$session_id"
}

write_headless_runner() {
  cat > "$HEADLESS_RUNNER" <<'EOF'
#!/bin/bash
set -euo pipefail

manifest_target="${WORKTREE_PATH}/manifests/worker-${WORKER_NAME}.md"

json_escape_text() {
  local value="$1"

  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

append_headless_log_line() {
  printf '%s\n' "$1" | tee -a "$HEADLESS_LOG_FILE"
}

json_field() {
  local field_name="$1"
  local line="$2"

  if command -v jq >/dev/null 2>&1; then
    jq -r --arg field_name "$field_name" '.[$field_name] // empty' <<<"$line" 2>/dev/null
    return 0
  fi

  printf '%s\n' "$line" | sed -n "s/.*\\\"${field_name}\\\"[[:space:]]*:[[:space:]]*\\\"\\([^\\\"]*\\)\\\".*/\\1/p" | tail -n 1
}

json_first_text() {
  local line="$1"

  if command -v jq >/dev/null 2>&1; then
    jq -r '[.. | objects | .text? // empty | select(. != "")][0] // empty' <<<"$line" 2>/dev/null
    return 0
  fi

  printf '%s\n' "$line" | sed -n 's/^.*"text"[[:space:]]*:[[:space:]]*"\(.*\)".*$/\1/p' | tail -n 1
}

json_usage_field() {
  local field_name="$1"
  local line="$2"

  if command -v jq >/dev/null 2>&1; then
    jq -r --arg field_name "$field_name" '.usage[$field_name] // .[$field_name] // empty' <<<"$line" 2>/dev/null
    return 0
  fi

  printf '%s\n' "$line" | sed -n "s/.*\\\"${field_name}\\\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" | tail -n 1
}

decode_legacy_json_text() {
  local value="$1"

  value=${value//\\n/$'\n'}
  value=${value//\\r/$'\r'}
  value=${value//\\t/$'\t'}
  value=${value//\\\//\/}
  value="$(printf '%s' "$value" | sed 's/\\"/"/g')"
  printf '%s' "$value"
}

render_json_event() {
  local line="$1"
  local event_type=""
  local thread_id=""
  local input_tokens=""
  local output_tokens=""
  local text_payload=""
  local rendered_text=""
  local rendered_line=""

  event_type="$(json_field type "$line")"

  case "$event_type" in
    thread.started)
      thread_id="$(json_field thread_id "$line")"
      append_headless_log_line "thread started: ${thread_id:-UNKNOWN}"
      return 0
      ;;
    turn.started)
      append_headless_log_line "turn started"
      return 0
      ;;
    turn.completed)
      input_tokens="$(json_usage_field input_tokens "$line")"
      output_tokens="$(json_usage_field output_tokens "$line")"
      if [ -n "$input_tokens" ] || [ -n "$output_tokens" ]; then
        append_headless_log_line "turn completed: input_tokens=${input_tokens:-0} output_tokens=${output_tokens:-0}"
      else
        append_headless_log_line "turn completed"
      fi
      return 0
      ;;
    item.completed)
      text_payload="$(json_first_text "$line")"
      if [ -n "$text_payload" ]; then
        rendered_text="$(decode_legacy_json_text "$text_payload")"
        while IFS= read -r rendered_line || [ -n "$rendered_line" ]; do
          append_headless_log_line "$rendered_line"
        done <<<"$rendered_text"
      else
        append_headless_log_line "event: item.completed"
      fi
      return 0
      ;;
  esac

  if [ -n "$event_type" ]; then
    append_headless_log_line "event: $event_type"
    return 0
  fi

  append_headless_log_line "$line"
}

write_legacy_event() {
  local line="$1"

  printf '{"type":"legacy.log","text":"%s"}\n' "$(json_escape_text "$line")" >> "$HEADLESS_EVENTS_FILE"
}

run_json_mode() {
  local line=""

  codex exec --dangerously-bypass-approvals-and-sandbox --json -m "$MODEL" -c "model_reasoning_effort=$EFFORT" -C "$WORKTREE_PATH" -o "$HEADLESS_FINAL_FILE" - < "$manifest_target" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$HEADLESS_EVENTS_FILE"
    render_json_event "$line"
  done
}

run_legacy_mode() {
  local line=""

  codex exec --dangerously-bypass-approvals-and-sandbox -m "$MODEL" -c "model_reasoning_effort=$EFFORT" -C "$WORKTREE_PATH" -o "$HEADLESS_FINAL_FILE" - < "$manifest_target" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
    append_headless_log_line "$line"
    write_legacy_event "$line"
  done
}

cd "$WORKTREE_PATH"
: > "$HEADLESS_LOG_FILE"
: > "$HEADLESS_EVENTS_FILE"
append_headless_log_line "[dispatch-worker] headless run started"
append_headless_log_line "[dispatch-worker] worktree: $WORKTREE_PATH"
append_headless_log_line "[dispatch-worker] events file: $HEADLESS_EVENTS_FILE"
append_headless_log_line "[dispatch-worker] final file: $HEADLESS_FINAL_FILE"

if codex exec --help 2>/dev/null | grep -q -- '--json'; then
  append_headless_log_line "[dispatch-worker] mode: codex exec --json"
  run_json_mode
else
  append_headless_log_line "[dispatch-worker] mode: codex exec text fallback"
  run_legacy_mode
fi
EOF
  chmod 700 "$HEADLESS_RUNNER"
  if [ -n "$RUN_USER" ]; then
    chown "$RUN_USER:$RUN_GROUP" "$HEADLESS_RUNNER"
  fi
}

run_headless_worker() {
  local run_status=0
  local session_id=""
  local timestamp=""
  local target_home="${HOME:-${DISPATCH_HOME}}"
  local target_path="${target_home}/.npm-global/bin:${DISPATCH_NPM_GLOBAL_BIN}:${TARGET_PATH_BASE}"

  timestamp="$(date +%Y%m%d-%H%M%S)"
  HEADLESS_OUTPUT_DIR="${HEADLESS_OUTPUT_DIR:-${CODEX_HEADLESS_ROOT}/${PROJECT}/${WORKER_NAME}}"
  HEADLESS_LOG_FILE="${HEADLESS_OUTPUT_DIR}/run-${timestamp}.log"
  HEADLESS_FINAL_FILE="${HEADLESS_OUTPUT_DIR}/final-${timestamp}.txt"
  HEADLESS_EVENTS_FILE="${HEADLESS_OUTPUT_DIR}/events-${timestamp}.jsonl"
  HEADLESS_RUNNER="${HEADLESS_OUTPUT_DIR}/run-${timestamp}.sh"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would run headless Codex worker in '$WORKTREE_PATH'"
    log "DRY-RUN: output directory '$HEADLESS_OUTPUT_DIR'"
    return 0
  fi

  CLEANUP_ON_FAILURE=0
  run_cmd "create headless output directory '$HEADLESS_OUTPUT_DIR'" mkdir -p "$HEADLESS_OUTPUT_DIR"
  if [ -n "$RUN_USER" ]; then
    run_cmd "change ownership of headless output directory '$HEADLESS_OUTPUT_DIR'" chown -R "$RUN_USER:$RUN_GROUP" "$HEADLESS_OUTPUT_DIR"
  fi

  write_headless_runner

  log "Starting headless Codex worker '$TMUX_SESSION'"
  set +e
  if [ -n "$RUN_USER" ]; then
    target_path="${RUN_HOME}/.npm-global/bin:${DISPATCH_NPM_GLOBAL_BIN}:${TARGET_PATH_BASE}"
    sudo -u "$RUN_USER" env "HOME=$RUN_HOME" "PATH=$target_path" "WORKTREE_PATH=$WORKTREE_PATH" "WORKER_NAME=$WORKER_NAME" "MODEL=$MODEL" "EFFORT=$EFFORT" "HEADLESS_LOG_FILE=$HEADLESS_LOG_FILE" "HEADLESS_FINAL_FILE=$HEADLESS_FINAL_FILE" "HEADLESS_EVENTS_FILE=$HEADLESS_EVENTS_FILE" bash "$HEADLESS_RUNNER"
    run_status=$?
  else
    env "HOME=$target_home" "PATH=$target_path" "WORKTREE_PATH=$WORKTREE_PATH" "WORKER_NAME=$WORKER_NAME" "MODEL=$MODEL" "EFFORT=$EFFORT" "HEADLESS_LOG_FILE=$HEADLESS_LOG_FILE" "HEADLESS_FINAL_FILE=$HEADLESS_FINAL_FILE" "HEADLESS_EVENTS_FILE=$HEADLESS_EVENTS_FILE" bash "$HEADLESS_RUNNER"
    run_status=$?
  fi
  set -e

  session_id="$(extract_headless_session_id)"
  CODEX_SESSION_ID="${session_id:-UNKNOWN}"

  if [ "$run_status" -eq 0 ]; then
    save_headless_session_record "$CODEX_SESSION_ID" "completed"
    log "Headless Codex worker completed"
    return 0
  fi

  save_headless_session_record "$CODEX_SESSION_ID" "blocked"
  warn "Headless Codex worker exited with status $run_status; preserved worktree and branch for resume"
  return "$run_status"
}

wait_for_codex_ready() {
  local session_name="$1"
  local max_wait="${2:-60}"
  local waited=0
  local pane_output=""

  while true; do
    capture_tmux_pane "$session_name" pane_output
    case "$pane_output" in
      *"›"*)
        return 0
        ;;
    esac

    if [ "$waited" -ge "$max_wait" ]; then
      printf '[%s] Recent tmux output for %s:\n%s\n' "$SCRIPT_NAME" "$session_name" "$pane_output" >&2
      die "Codex prompt not ready in tmux session '$session_name' within ${max_wait}s. Attach with 'tmux attach -t $session_name' to inspect the failure."
    fi

    pause 2
    waited=$((waited + 2))
  done
}

confirm_trust_prompt_if_needed() {
  local session_name="$1"
  local pane_output=""

  pause 5
  capture_tmux_pane "$session_name" pane_output
  case "$pane_output" in
    *"Do you trust"*)
      log "Confirming Codex trust prompt in tmux session '$session_name'"
      run_cmd "confirm Codex trust prompt in '$session_name'" tmux send-keys -t "$session_name" Enter
      ;;
  esac
}

verify_manifest_processing() {
  local session_name="$1"
  local pane_output=""

  pause 15
  capture_tmux_pane "$session_name" pane_output
  case "$pane_output" in
    *"100% left"*)
      log "Codex still shows 100% left after manifest delivery; sending additional Enter"
      run_cmd "nudge Codex manifest processing in '$session_name'" tmux send-keys -t "$session_name" Enter
      pause 15
      capture_tmux_pane "$session_name" pane_output
      case "$pane_output" in
        *"100% left"*)
          warn "Codex still shows 100% left after manifest nudge. Attach with 'tmux attach -t $session_name' if the worker does not start."
          ;;
      esac
      ;;
  esac
}

latest_rollout_after_marker() {
  local marker_file="$1"
  local output=""
  local status=0
  local line
  local newest_time=0
  local newest_file=""
  local entry_time=0
  local entry_file=""

  if [ ! -d "$CODEX_SESSION_ROOT" ]; then
    warn "Codex session directory '$CODEX_SESSION_ROOT' is missing; session ID discovery will be skipped."
    printf '\n'
    return 0
  fi

  set +e
  output="$(find "$CODEX_SESSION_ROOT" -name 'rollout-*.jsonl' -type f -newer "$marker_file" -exec stat -c '%Y %n' {} + 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    warn "Failed to inspect Codex session files after '$marker_file': $output"
    printf '\n'
    return 0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    entry_time="${line%% *}"
    entry_file="${line#* }"
    if [ -z "$newest_file" ] || [ "$entry_time" -gt "$newest_time" ]; then
      newest_time="$entry_time"
      newest_file="$entry_file"
    fi
  done <<<"$output"

  printf '%s\n' "$newest_file"
}

spawn_or_reuse_session() {
  local -a spawn_args=()
  local status=0

  # Edge cases:
  # - Re-runs reuse the existing tmux session and re-deliver the manifest.
  # - Cleanup only removes the session when this invocation created it.
  if tmux_session_exists "$TMUX_SESSION"; then
    log "Reusing existing tmux session '$TMUX_SESSION'"
    return 0
  fi

  spawn_args=(--name "$TMUX_SESSION" --project-dir "$WORKTREE_PATH" --model "$MODEL" --effort "$EFFORT")
  if [ -n "$RUN_USER" ]; then
    spawn_args+=(--user "$RUN_USER")
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would spawn Codex session '$TMUX_SESSION'"
    printf '  %s\n' "$(show_command "$SPAWN_SCRIPT" "${spawn_args[@]}")"
    return 0
  fi

  log "Spawning Codex session '$TMUX_SESSION'"
  set +e
  SPAWN_OUTPUT="$("$SPAWN_SCRIPT" "${spawn_args[@]}" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$SPAWN_OUTPUT"

  if tmux_session_exists "$TMUX_SESSION"; then
    SESSION_CREATED=1
  fi

  if [ "$status" -ne 0 ]; then
    if [ "$SESSION_CREATED" -eq 1 ]; then
      warn "spawn-codex.sh exited with status $status, but tmux session '$TMUX_SESSION' exists. Continuing with the existing session."
      return 0
    fi
    die "spawn-codex.sh failed before tmux session '$TMUX_SESSION' became available: $SPAWN_OUTPUT. Fix the spawn error and retry."
  fi
}

deliver_manifest() {
  local manifest_content=""
  local prompt_payload=""

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would send manifest '$MANIFEST_FILE' into tmux session '$TMUX_SESSION'"
    return 0
  fi

  if ! manifest_content="$(<"$MANIFEST_FILE")"; then
    die "Failed to read manifest file '$MANIFEST_FILE' before delivery. Check file permissions and retry."
  fi

  prompt_payload="$(printf 'Read the following worker manifest and follow all instructions exactly.\nSource file: %s\n\n%s' "$MANIFEST_FILE" "$manifest_content")"
  log "Delivering manifest via tmux send-keys -l"
  run_cmd "send manifest payload to '$TMUX_SESSION'" tmux send-keys -t "$TMUX_SESSION" -l -- "$prompt_payload"
  pause 0.5
  run_cmd "submit manifest payload in '$TMUX_SESSION'" tmux send-keys -t "$TMUX_SESSION" Enter
  verify_manifest_processing "$TMUX_SESSION"
}

discover_codex_session_id() {
  local session_id=""
  local rollout_path=""
  local waited=0

  session_id="$(extract_uuid "$(extract_field "Codex Session" "$SPAWN_OUTPUT")")"
  if [ -n "$session_id" ]; then
    printf '%s\n' "$session_id"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY_RUN\n'
    return 0
  fi

  log "Waiting for Codex session ID after manifest delivery"
  while [ "$waited" -lt 90 ]; do
    rollout_path="$(latest_rollout_after_marker "$MANIFEST_MARKER")"
    session_id="$(extract_uuid "$rollout_path")"
    if [ -n "$session_id" ]; then
      printf '%s\n' "$session_id"
      return 0
    fi
    pause 2
    waited=$((waited + 2))
  done

  printf 'UNKNOWN\n'
}

cleanup() {
  local exit_code=$?

  set +e

  if [ -n "$MANIFEST_MARKER" ] && [ -e "$MANIFEST_MARKER" ]; then
    rm -f -- "$MANIFEST_MARKER" >/dev/null 2>&1 || warn "Failed to remove marker '$MANIFEST_MARKER'. Remove it manually if needed."
  fi

  if [ "$exit_code" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ "$CLEANUP_ON_FAILURE" -eq 0 ]; then
      log "Preserving worktree/session after failure for inspection or resume"
      trap - EXIT
      exit "$exit_code"
    fi

    # Cleanup only resources created by this invocation so idempotent re-runs do not destroy
    # pre-existing worktrees or tmux sessions.
    if [ "$SESSION_CREATED" -eq 1 ] && [ -n "$TMUX_SESSION" ] && tmux_session_exists "$TMUX_SESSION"; then
      log "Cleaning up tmux session '$TMUX_SESSION' after failure"
      tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || warn "Failed to remove tmux session '$TMUX_SESSION'. Run 'tmux kill-session -t $TMUX_SESSION' after inspecting it."
    fi

    if [ "$WORKTREE_CREATED" -eq 1 ] && [ -n "$WORKTREE_PATH" ]; then
      log "Cleaning up worktree '$WORKTREE_PATH' after failure"
      git worktree remove --force "$WORKTREE_PATH" >/dev/null 2>&1 || warn "Failed to remove worktree '$WORKTREE_PATH'. Run 'git worktree remove --force \"$WORKTREE_PATH\"' once it is safe."
    fi

    if [ "$BRANCH_CREATED" -eq 1 ] && [ -n "$BRANCH_NAME" ] && git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
      log "Cleaning up local branch '$BRANCH_NAME' after failure"
      git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || warn "Failed to delete local branch '$BRANCH_NAME'. Run 'git branch -D \"$BRANCH_NAME\"' after removing the worktree."
    fi
  fi

  trap - EXIT
  exit "$exit_code"
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      require_option_value "$1" "${2:-}"
      PROJECT="$2"
      shift 2
      ;;
    --worker-name)
      require_option_value "$1" "${2:-}"
      WORKER_NAME="$2"
      shift 2
      ;;
    --manifest-file)
      require_option_value "$1" "${2:-}"
      MANIFEST_FILE="$2"
      shift 2
      ;;
    --model)
      require_option_value "$1" "${2:-}"
      MODEL="$2"
      shift 2
      ;;
    --effort)
      require_option_value "$1" "${2:-}"
      EFFORT="$2"
      shift 2
      ;;
    --backend)
      require_option_value "$1" "${2:-}"
      BACKEND="$2"
      shift 2
      ;;
    --headless)
      BACKEND="headless"
      shift
      ;;
    --user)
      require_option_value "$1" "${2:-}"
      RUN_USER="$2"
      shift 2
      ;;
    --codex-api-key-file)
      require_option_value "$1" "${2:-}"
      CODEX_API_KEY_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown argument: $1. Use --help to review supported options."
      ;;
  esac
done

[ -n "$PROJECT" ] || die "--project is required. Re-run with --project PROJECT."
[ -n "$WORKER_NAME" ] || die "--worker-name is required. Re-run with --worker-name NAME."
[ -n "$MANIFEST_FILE" ] || die "--manifest-file is required. Re-run with --manifest-file FILE."
case "$BACKEND" in
  tui|headless)
    ;;
  *)
    die "--backend must be either 'tui' or 'headless'."
    ;;
esac

ensure_file_is_readable_and_nonempty "$MANIFEST_FILE" "Manifest file"

require_cmd git
require_cmd mktemp
require_cmd find
require_cmd stat
require_cmd cat
require_cmd cp
require_cmd sleep
if [ "$BACKEND" = "headless" ]; then
  require_cmd tee
else
  require_cmd tmux
fi
if [ -n "$RUN_USER" ]; then
  require_cmd id
  require_cmd getent
  require_cmd chown
fi

validate_run_user "$RUN_USER"
if [ -n "$RUN_HOME" ]; then
  CODEX_SESSION_ROOT="${RUN_HOME}/.codex/sessions"
fi
configure_codex_api_key_auth

if [ "$BACKEND" != "headless" ]; then
  if ! SPAWN_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spawn-codex.sh"; then
    die "Failed to resolve script directory for spawn-codex.sh. Run the script from a readable checkout and retry."
  fi
  [ -x "$SPAWN_SCRIPT" ] || die "spawn-codex.sh is not executable: $SPAWN_SCRIPT. Fix the file mode and retry."
fi

run_readonly_cmd "verify the current directory is inside a git repository" git rev-parse --git-dir >/dev/null 2>&1
if ! REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"; then
  die "Failed to resolve the main repository root. Run the script from a readable git checkout and retry."
fi

TMUX_SESSION="worker-${PROJECT}-${WORKER_NAME}"
BRANCH_NAME="worker/${PROJECT}-${WORKER_NAME}"
WORKTREE_PATH="${REPO_ROOT}/.letta/worktrees/worker-${PROJECT}-${WORKER_NAME}"
WORKTREE_PARENT="${WORKTREE_PATH%/*}"

ensure_directory_exists "$WORKTREE_PARENT" "worktree parent directory"
if [ "$DRY_RUN" -eq 1 ] && [ ! -d "$WORKTREE_PARENT" ]; then
  log "DRY-RUN: skipping access check for worktree parent directory that would be created"
else
  ensure_directory_access "$WORKTREE_PARENT" "worktree parent directory"
fi

MANIFEST_MARKER="$(mktemp "/tmp/.dispatch-worker-marker.XXXXXX")"

ensure_worktree
configure_worktree

if [ "$BACKEND" = "headless" ]; then
  run_headless_worker
  printf '\n'
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '=== WORKER DRY RUN COMPLETE ===\n'
  else
    printf '=== HEADLESS WORKER COMPLETE ===\n'
  fi
  printf 'Backend:         %s\n' "$BACKEND"
  printf 'Codex Session:   %s\n' "${CODEX_SESSION_ID:-DRY_RUN}"
  printf 'Worktree:        %s\n' "$WORKTREE_PATH"
  printf 'Branch:          %s\n' "$BRANCH_NAME"
  printf 'Manifest:        %s\n' "$MANIFEST_FILE"
  printf 'Log File:        %s\n' "${HEADLESS_LOG_FILE:-DRY_RUN}"
  printf 'Final File:      %s\n' "${HEADLESS_FINAL_FILE:-DRY_RUN}"
  printf 'Events File:     %s\n' "${HEADLESS_EVENTS_FILE:-DRY_RUN}"
  exit 0
fi

spawn_or_reuse_session

if [ "$DRY_RUN" -eq 0 ]; then
  confirm_trust_prompt_if_needed "$TMUX_SESSION"
  wait_for_codex_ready "$TMUX_SESSION" 30
fi

deliver_manifest

CODEX_SESSION_ID="$(discover_codex_session_id)"

printf '\n'
if [ "$DRY_RUN" -eq 1 ]; then
  printf '=== WORKER DRY RUN COMPLETE ===\n'
else
  printf '=== WORKER DISPATCH COMPLETE ===\n'
fi
printf 'Tmux Session:    %s\n' "$TMUX_SESSION"
printf 'Codex Session:   %s\n' "$CODEX_SESSION_ID"
printf 'Worktree:        %s\n' "$WORKTREE_PATH"
printf 'Branch:          %s\n' "$BRANCH_NAME"
printf 'Manifest:        %s\n' "$MANIFEST_FILE"
