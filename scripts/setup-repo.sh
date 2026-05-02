#!/bin/bash

set -euo pipefail

: "${DISPATCH_HOME:?DISPATCH_HOME must be set}"

SCRIPT_NAME=$(basename "$0")
PROJECT_NAME="${PROJECT_NAME:-}"
REPO_INPUT="${REPO_FULL:-}"
REPO_FULL=""
BRANCH="${BRANCH:-main}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
DRY_RUN=false
LOOP_ROOT="${SETUP_REPO_LOOP_ROOT:-${DISPATCH_HOME}/repos}"

usage() {
  cat <<EOF
Usage: ./${SCRIPT_NAME} --project PROJECT_NAME --repo OWNER/REPO [--branch BRANCH] [--dry-run]

Clone a GitHub repository into ${LOOP_ROOT}/\${project}/ and create a
project-specific CLAUDE.md context file.

Options:
  --project PROJECT_NAME   Project slug. Falls back to PROJECT_NAME env var.
  --repo OWNER/REPO        GitHub repository or GitHub URL. Falls back to REPO_FULL env var.
  --branch BRANCH          Branch to clone. Falls back to BRANCH env var, default: main.
  --dry-run                Validate inputs and log planned actions without changing the system.
  --help                   Show this help text.

Required environment:
  GITHUB_TOKEN             GitHub token used for the initial clone when the repo is absent.
EOF
}

log() {
  echo "[setup-repo] $*"
}

warn() {
  echo "[setup-repo] WARN: $*" >&2
}

die() {
  echo "[setup-repo] ERROR: $*" >&2
  exit 1
}

sanitize_text() {
  printf '%s' "${1:-}" | sed -E \
    -e 's#(https?://)[^/@]+@#\1#g' \
    -e 's#(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]]+#\1[REDACTED]#g' \
    -e 's#(gh[pousr]_|github_pat_)[A-Za-z0-9_]+#\1[REDACTED]#g'
}

run_cmd() {
  local display

  display="$(printf '%q ' "$@")"
  display="${display% }"
  display="$(sanitize_text "$display")"

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: $display"
    return 0
  fi

  "$@"
}

normalize_repo_full() {
  local raw="$1"
  local path="$raw"

  case "$raw" in
    https://github.com/*)
      path="${raw#https://github.com/}"
      ;;
    git@github.com:*)
      path="${raw#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      path="${raw#ssh://git@github.com/}"
      ;;
  esac

  path="${path%/}"
  path="${path%.git}"

  if [[ "$path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf '%s' "$path"
    return 0
  fi

  return 1
}

describe_clone_failure() {
  local clone_log="$1"

  if grep -qiE 'Authentication failed|Repository not found|Permission denied|403|could not read Username|could not read from remote repository|invalid username or token|password authentication was removed' "$clone_log"; then
    printf '%s' "authentication, authorization, or repository access issue"
  elif grep -qiE 'Could not resolve host|Failed to connect|Connection timed out|Connection refused|network is unreachable|Operation timed out|TLS handshake timeout|remote end hung up unexpectedly' "$clone_log"; then
    printf '%s' "network connectivity issue"
  elif grep -qiE 'No space left on device|Disk quota exceeded|Read-only file system|unable to create file|No such file or directory' "$clone_log"; then
    printf '%s' "disk or filesystem issue"
  else
    printf '%s' "unknown git clone failure"
  fi
}

write_claude_md() {
  local repo_name="$1"

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: write ${CLAUDE_MD_PATH}"
    return 0
  fi

  cat >"$CLAUDE_MD_PATH" <<EOF
# ${PROJECT_NAME}

Automated dispatch pipeline workspace for ${PROJECT_NAME}.

## Project
- Repo: ${REPO_FULL}
- Branch: ${BRANCH}
- VPS path: ${TARGET_DIR}/
- Project user: ${PROJECT_USER}

## Your Role (CCC Web Master)
Operate this project environment:
- Review worker branches and integrate approved changes
- Coordinate workers and handle escalation when blocked
- Avoid changing dispatch architecture or machine setup without explicit direction

## Expected Layout
- scripts/ — setup, spawn, dispatch, teardown automation
- templates/ — CCC bootstrap, worker manifests, personas
- docs/ — variables, flow context, operational references

## Naming
- CCC tmux: ccc-${PROJECT_NAME}
- Repo Master tmux: repo-master-${PROJECT_NAME}
- Worker tmux prefix: worker-${PROJECT_NAME}-
- Repo directory: ${TARGET_DIR}/

## Constraints
- Bash scripts use set -euo pipefail
- Target host: Ubuntu 24.04 VPS
- GitHub repo name: ${repo_name}
- Keep changes scoped to the assigned worker/task
EOF
}

prepare_project_workspace() {
  local worktree_parent="${TARGET_DIR}/.letta/worktrees"

  run_cmd mkdir -p "$worktree_parent"

  if id "$PROJECT_USER" >/dev/null 2>&1; then
    run_cmd chown -R "$PROJECT_USER:$PROJECT_USER" "$TARGET_DIR"
    run_cmd git config --global --add safe.directory "$TARGET_DIR"
    log "Prepared ${TARGET_DIR} ownership and .letta/worktrees for ${PROJECT_USER}"
  else
    warn "Project user not found, leaving ${TARGET_DIR} owned by current user"
  fi
}

clone_repo() {
  local clone_log
  local failure_reason
  local clone_output

  clone_log="$(mktemp)"

  if [[ "$DRY_RUN" == true ]]; then
    run_cmd git clone --branch "$BRANCH" "$AUTH_URL" "$TARGET_DIR"
    rm -f "$clone_log"
    return 0
  fi

  if git clone --branch "$BRANCH" "$AUTH_URL" "$TARGET_DIR" 2>"$clone_log"; then
    rm -f "$clone_log"
    return 0
  fi

  failure_reason="$(describe_clone_failure "$clone_log")"
  clone_output="$(sanitize_text "$(cat "$clone_log")")"

  if [[ -n "$clone_output" ]]; then
    warn "git clone stderr: $clone_output"
  fi

  rm -f "$clone_log"

  if [[ -e "$TARGET_DIR" && ! -d "$TARGET_DIR/.git" ]]; then
    warn "Removing partial clone directory at ${TARGET_DIR}"
    rm -rf "$TARGET_DIR"
  fi

  die "git clone failed for ${REPO_FULL}@${BRANCH} (${failure_reason})"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_NAME="${2:-}"
      shift 2
      ;;
    --repo)
      REPO_INPUT="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run as root."
fi

if [ -z "$PROJECT_NAME" ]; then
  usage >&2
  die "--project is required."
fi

if [ -z "$REPO_INPUT" ]; then
  usage >&2
  die "--repo is required."
fi

if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  die "Project name must match ^[a-z0-9][a-z0-9-]*$"
fi

if [[ -z "$BRANCH" ]]; then
  die "--branch must not be empty."
fi

if ! REPO_FULL="$(normalize_repo_full "$REPO_INPUT")"; then
  die "Repository must be OWNER/REPO or a GitHub URL (https://github.com/OWNER/REPO(.git), git@github.com:OWNER/REPO.git)"
fi

REPO_NAME="${REPO_FULL#*/}"
PROJECT_USER="ccuser-${PROJECT_NAME}"
TARGET_DIR="${LOOP_ROOT}/${PROJECT_NAME}"
CLAUDE_MD_PATH="${TARGET_DIR}/CLAUDE.md"
AUTH_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_FULL}.git"
CLEAN_URL="https://github.com/${REPO_FULL}.git"
PROJECT_LINK="/home/${PROJECT_USER}/project"

run_cmd mkdir -p "$LOOP_ROOT"

if [[ -d "$TARGET_DIR/.git" ]]; then
  CURRENT_REMOTE="$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$CURRENT_REMOTE" ]]; then
    if ! CURRENT_REPO_FULL="$(normalize_repo_full "$CURRENT_REMOTE")"; then
      die "Existing repo at $TARGET_DIR has an unsupported origin URL: $(sanitize_text "$CURRENT_REMOTE")"
    fi

    if [[ "$CURRENT_REPO_FULL" != "$REPO_FULL" ]]; then
      die "Existing repo at $TARGET_DIR points to $(sanitize_text "$CURRENT_REMOTE"), expected $CLEAN_URL"
    fi
  fi

  log "Repo already present at $TARGET_DIR"
else
  if [ -e "$TARGET_DIR" ]; then
    die "Target path exists and is not a git repo: $TARGET_DIR"
  fi

  if [[ "$DRY_RUN" != true && -z "$GITHUB_TOKEN" ]]; then
    die "GITHUB_TOKEN is required to clone ${REPO_FULL}."
  fi

  log "Cloning ${REPO_FULL} (${BRANCH}) into ${TARGET_DIR}"
  clone_repo
fi

run_cmd git -C "$TARGET_DIR" remote set-url origin "$CLEAN_URL"

write_claude_md "$REPO_NAME"
log "Wrote ${CLAUDE_MD_PATH}"
prepare_project_workspace

if id "$PROJECT_USER" >/dev/null 2>&1; then
  run_cmd ln -sfn "$TARGET_DIR" "$PROJECT_LINK"
  run_cmd chown -h "$PROJECT_USER:$PROJECT_USER" "$PROJECT_LINK"
  log "Linked ${PROJECT_LINK} -> ${TARGET_DIR}"
else
  warn "Project user not found, skipping ${PROJECT_LINK} symlink"
fi

log "Repo ready: $TARGET_DIR"
