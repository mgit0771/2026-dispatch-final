#!/usr/bin/env bash
set -euo pipefail
NAME="$(basename "$0")"
INSTANCE_ID=""
OWNER_PAT_FILE=""
ANTHROPIC_KEY_FILE=""
CODEX_KEY_FILE=""
DISPATCH_HOME=""
SSOT_REPO="mgit0771/2026-dispatch-final"
DRY_RUN=0
USER_NAME=""
CONFIG_DIR=""
REGISTRY_DIR=""
REPO_DIR=""
usage() {
  cat <<'EOF'
Usage:
  ./bootstrap.sh --instance-id ID --owner-pat-file PATH --anthropic-key-file PATH --codex-key-file PATH [--dispatch-home PATH] [--ssot-repo OWNER/REPO] [--dry-run]
EOF
}
log() { printf '[%s] %s\n' "$NAME" "$*"; }
die() {
  printf '[%s] ERROR: %s\n' "$NAME" "$*" >&2
  exit 1
}
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[%s] DRY-RUN:' "$NAME"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

need_file_600() {
  [ -f "$1" ] || die "File not found: $1"
  [ -r "$1" ] || die "File is not readable: $1"
  [ "$(stat -c '%a' "$1")" = "600" ] || die "File must have mode 600: $1"
}

validate_id() {
  [[ "$INSTANCE_ID" =~ ^[a-z0-9]([a-z0-9-]{0,23}[a-z0-9])?$|^[a-z0-9]$ ]] \
    || die "--instance-id must use lowercase letters, digits, or dashes; start/end alnum; max 25 chars."
  USER_NAME="dispatcher-${INSTANCE_ID}"
  [ "${#USER_NAME}" -le 32 ] \
    || die "--instance-id '${INSTANCE_ID}' would create Linux account '${USER_NAME}' longer than 32 chars. Effective safe max on this host is 20."
}

set_paths() {
  [ -n "$DISPATCH_HOME" ] || DISPATCH_HOME="/home/${USER_NAME}"
  CONFIG_DIR="${DISPATCH_HOME}/.config"
  REGISTRY_DIR="${DISPATCH_HOME}/registries"
  REPO_DIR="${DISPATCH_HOME}/dispatch"
}

ensure_sudo() {
  need_cmd sudo
  if [ "$(id -u)" -ne 0 ]; then
    sudo -n true >/dev/null 2>&1 || die "sudo -n true failed; run as root or with passwordless sudo."
  fi
}

preflight() {
  local cmd=""
  for cmd in git getent install mktemp stat sudo useradd awk grep; do need_cmd "$cmd"; done
  validate_id
  set_paths
  need_file_600 "$OWNER_PAT_FILE"
  need_file_600 "$ANTHROPIC_KEY_FILE"
  need_file_600 "$CODEX_KEY_FILE"
  ensure_sudo
  case "$SSOT_REPO" in */*) ;; *) die "--ssot-repo must look like OWNER/REPO" ;; esac
  log "Phase 1/6 pre-flight: OK (instance=${INSTANCE_ID}, user=${USER_NAME}, home=${DISPATCH_HOME})"
}

create_user_if_needed() {
  local existing_home=""
  if getent passwd "$USER_NAME" >/dev/null 2>&1; then
    existing_home="$(getent passwd "$USER_NAME" | awk -F: '{print $6}')"
    [ "$existing_home" = "$DISPATCH_HOME" ] \
      || die "User ${USER_NAME} already exists with home ${existing_home}; rerun with --dispatch-home ${existing_home}."
    log "Phase 2/6 create user: exists (${USER_NAME})"
  else
    run useradd -m -d "$DISPATCH_HOME" -s /bin/bash "$USER_NAME"
    log "Phase 2/6 create user: created (${USER_NAME})"
  fi
  run install -d -o "$USER_NAME" -g "$USER_NAME" -m 755 "$DISPATCH_HOME"
}

write_askpass() {
  local path="$1"
  cat >"$path" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) exec cat $(printf '%q' "$OWNER_PAT_FILE") ;;
  *) printf '\n' ;;
esac
EOF
  chmod 700 "$path"
}

clone_repo() {
  local askpass="" origin_url=""
  if [ -d "${REPO_DIR}/.git" ]; then
    origin_url="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
    printf '%s\n' "$origin_url" | grep -Eq "github\.com[:/]${SSOT_REPO}(\.git)?$" \
      || die "Existing checkout at ${REPO_DIR} points to unexpected origin: ${origin_url:-<none>}"
    log "Phase 3/6 clone SSOT: existing checkout kept (${REPO_DIR})"
    return 0
  fi

  run install -d -o "$USER_NAME" -g "$USER_NAME" -m 755 "$DISPATCH_HOME"

  if [ "$DRY_RUN" -eq 1 ]; then
    run sudo -u "$USER_NAME" env HOME="$DISPATCH_HOME" git clone --depth 1 "https://github.com/${SSOT_REPO}.git" "$REPO_DIR"
    log "Phase 3/6 clone SSOT: planned (${REPO_DIR})"
    return 0
  fi

  askpass="$(mktemp)"
  trap 'rm -f "$askpass"' EXIT
  write_askpass "$askpass"
  sudo -u "$USER_NAME" env HOME="$DISPATCH_HOME" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \
    git clone --depth 1 "https://github.com/${SSOT_REPO}.git" "$REPO_DIR"
  rm -f "$askpass"
  trap - EXIT
  log "Phase 3/6 clone SSOT: cloned (${REPO_DIR})"
}

install_secret() {
  run install -d -o "$USER_NAME" -g "$USER_NAME" -m 700 "$CONFIG_DIR"
  run install -o "$USER_NAME" -g "$USER_NAME" -m 600 "$1" "$2"
}

copy_credentials() {
  install_secret "$ANTHROPIC_KEY_FILE" "${CONFIG_DIR}/anthropic-api-key"
  install_secret "$CODEX_KEY_FILE" "${CONFIG_DIR}/openai-api-key"
  install_secret "$CODEX_KEY_FILE" "${CONFIG_DIR}/codex-api-key"
  install_secret "$OWNER_PAT_FILE" "${CONFIG_DIR}/github-pat"
  log "Phase 4/6 copy creds: installed under ${CONFIG_DIR}"
}

init_dirs() {
  local dir=""
  for dir in \
    "$DISPATCH_HOME/repos" \
    "$DISPATCH_HOME/.codex-headless" \
    "$DISPATCH_HOME/.ccc-headless" \
    "$DISPATCH_HOME/logs" \
    "$REGISTRY_DIR"
  do
    run install -d -o "$USER_NAME" -g "$USER_NAME" -m 755 "$dir"
  done
  log "Phase 5/6 init dirs: ready"
}

init_registries() {
  local file=""
  for file in codex-sessions.jsonl letta-sessions.jsonl ccc-sessions.jsonl; do
    run install -o "$USER_NAME" -g "$USER_NAME" -m 600 /dev/null "${REGISTRY_DIR}/${file}"
  done
  log "Phase 6/6 init registries: ready"
}

print_final() {
  printf 'Dispatcher %s ready.\n' "$USER_NAME"
  printf 'Home: %s\n' "$DISPATCH_HOME"
  printf 'Repo: %s\n' "$REPO_DIR"
  printf 'Run dispatch via: sudo -u %s bash %s/scripts/dispatch-loop-hardened.sh ...\n' "$USER_NAME" "$REPO_DIR"
  printf 'Set DISPATCH_HOME=%s before invoking dispatch-* scripts (or source the env file).\n' "$DISPATCH_HOME"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --instance-id) INSTANCE_ID="${2:-}"; shift 2 ;;
    --owner-pat-file) OWNER_PAT_FILE="${2:-}"; shift 2 ;;
    --anthropic-key-file) ANTHROPIC_KEY_FILE="${2:-}"; shift 2 ;;
    --codex-key-file) CODEX_KEY_FILE="${2:-}"; shift 2 ;;
    --dispatch-home) DISPATCH_HOME="${2:-}"; shift 2 ;;
    --ssot-repo) SSOT_REPO="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[ -n "$INSTANCE_ID" ] || die "--instance-id is required"
[ -n "$OWNER_PAT_FILE" ] || die "--owner-pat-file is required"
[ -n "$ANTHROPIC_KEY_FILE" ] || die "--anthropic-key-file is required"
[ -n "$CODEX_KEY_FILE" ] || die "--codex-key-file is required"

preflight
create_user_if_needed
clone_repo
copy_credentials
init_dirs
init_registries
print_final
