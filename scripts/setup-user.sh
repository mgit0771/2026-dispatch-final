#!/bin/bash

set -euo pipefail

: "${DISPATCH_HOME:?DISPATCH_HOME must be set}"

SCRIPT_NAME=$(basename "$0")
TARGET_PATH_BASE="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
LOOP_ROOT="${SETUP_USER_LOOP_ROOT:-${DISPATCH_HOME}/repos}"
DISPATCH_NPM_GLOBAL_BIN="${SETUP_USER_DISPATCH_NPM_GLOBAL_BIN:-${DISPATCH_HOME}/.npm-global/bin}"
DEFAULT_SOURCE_CLAUDE_HOME="${SETUP_USER_DEFAULT_SOURCE_CLAUDE_HOME:-${DISPATCH_HOME}}"
FALLBACK_SOURCE_CLAUDE_HOME="${SETUP_USER_FALLBACK_SOURCE_CLAUDE_HOME:-}"
SOURCE_CODEX_DIR="${SETUP_USER_SOURCE_CODEX_DIR:-${DISPATCH_HOME}/.codex}"
PROJECT_NAME="${PROJECT_NAME:-}"
DRY_RUN=false
TEST_REFRESH=false
CODEX_API_KEY_FILE="${CODEX_API_KEY_FILE:-}"
SOURCE_CLAUDE_USER="${SOURCE_CLAUDE_USER:-}"
SOURCE_CLAUDE_HOME=""
SOURCE_CLAUDE_DIR=""
SOURCE_CREDENTIALS_FILE=""
CREDENTIAL_EXPIRY_WARN_DAYS="${CREDENTIAL_EXPIRY_WARN_DAYS:-7}"
# OAuth auto-refresh: if the source token has fewer seconds remaining than this,
# attempt a refresh via the vendor token endpoint before copying. Default 2h.
OAUTH_REFRESH_THRESHOLD_SECONDS="${OAUTH_REFRESH_THRESHOLD_SECONDS:-7200}"
# Public Claude Code OAuth client_id — override via env if the vendor changes it.
CLAUDE_OAUTH_CLIENT_ID="${CLAUDE_OAUTH_CLIENT_ID:-9d1c250a-e61b-44d9-88ed-5944d1962f5e}"
CLAUDE_OAUTH_TOKEN_URL="${CLAUDE_OAUTH_TOKEN_URL:-https://claude.com/oauth/token}"
CODEX_OAUTH_TOKEN_URL="${CODEX_OAUTH_TOKEN_URL:-https://auth.openai.com/oauth/token}"

usage() {
  cat <<EOF
Usage: ./${SCRIPT_NAME} --project PROJECT_NAME [--source-user USER] [--codex-api-key-file FILE] [--dry-run] [--test-refresh]

Create or update a per-project Linux user and copy Claude/Codex credentials from
the preferred dispatcher-scoped source home (${DEFAULT_SOURCE_CLAUDE_HOME}/.claude).
Before copying, auto-refreshes OAuth tokens that are within
\${OAUTH_REFRESH_THRESHOLD_SECONDS} (default 7200s) of expiry so the new user
starts with a long-lived token and avoids the manual re-auth browser flow.

Options:
  --project PROJECT_NAME   Project slug. Falls back to PROJECT_NAME env var.
  --source-user USER       Copy Claude state from USER's home before default dispatcher lookup.
  --codex-api-key-file FILE
                          Configure project-user Codex API-key login from this dispatcher-readable file.
  --dry-run                Validate inputs and log planned actions without changing the system.
  --test-refresh           After credential copy, run a warning-only Claude print-mode auth smoke test as the project user.
  --help                   Show this help text.
EOF
}

log() {
  echo "[setup-user] $*"
}

warn() {
  echo "[setup-user] WARN: $*" >&2
}

die() {
  echo "[setup-user] ERROR: $*" >&2
  exit 1
}

run_cmd() {
  local display

  display="$(printf '%q ' "$@")"
  display="${display% }"

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: $display"
    return 0
  fi

  "$@"
}

lookup_user_home() {
  local user_name="$1"
  local passwd_entry=""

  passwd_entry="$(getent passwd "$user_name" || true)"
  [ -n "$passwd_entry" ] || return 1
  printf '%s\n' "$passwd_entry" | cut -d: -f6
}

set_source_claude_home() {
  local source_home="$1"
  local reason="$2"

  SOURCE_CLAUDE_HOME="$source_home"
  SOURCE_CLAUDE_DIR="${source_home}/.claude"
  SOURCE_CREDENTIALS_FILE="${SOURCE_CLAUDE_DIR}/.credentials.json"

  if [[ "$reason" == "explicit" ]]; then
    log "Using explicit Claude source home: ${SOURCE_CLAUDE_HOME}"
  fi
}

resolve_source_claude_dir() {
  local explicit_home=""

  if [[ -n "$SOURCE_CLAUDE_USER" ]]; then
    if ! explicit_home="$(lookup_user_home "$SOURCE_CLAUDE_USER")"; then
      die "Source Claude user does not exist: ${SOURCE_CLAUDE_USER}"
    fi
    if [[ ! -d "${explicit_home}/.claude" ]]; then
      die "Source Claude directory not found for ${SOURCE_CLAUDE_USER}: ${explicit_home}/.claude"
    fi
    set_source_claude_home "$explicit_home" "explicit"
    if [[ ! -f "$SOURCE_CREDENTIALS_FILE" ]]; then
      warn "Claude credentials file missing in ${SOURCE_CLAUDE_DIR}; unavailable files will be skipped"
    fi
    return 0
  fi

  if [[ -f "${DEFAULT_SOURCE_CLAUDE_HOME}/.claude/.credentials.json" ]]; then
    set_source_claude_home "$DEFAULT_SOURCE_CLAUDE_HOME" "default"
    return 0
  fi

  if [[ -n "$FALLBACK_SOURCE_CLAUDE_HOME" && -f "${FALLBACK_SOURCE_CLAUDE_HOME}/.claude/.credentials.json" ]]; then
    set_source_claude_home "$FALLBACK_SOURCE_CLAUDE_HOME" "fallback"
    log "Primary Claude credentials not found, falling back to ${SOURCE_CLAUDE_DIR}"
    return 0
  fi

  if [[ -d "${DEFAULT_SOURCE_CLAUDE_HOME}/.claude" ]]; then
    set_source_claude_home "$DEFAULT_SOURCE_CLAUDE_HOME" "default"
    warn "Claude credentials file missing in ${SOURCE_CLAUDE_DIR}; unavailable files will be skipped"
    return 0
  fi

  if [[ -n "$FALLBACK_SOURCE_CLAUDE_HOME" && -d "${FALLBACK_SOURCE_CLAUDE_HOME}/.claude" ]]; then
    set_source_claude_home "$FALLBACK_SOURCE_CLAUDE_HOME" "fallback"
    warn "Claude credentials file missing in ${SOURCE_CLAUDE_DIR}; unavailable files will be skipped"
    return 0
  fi

  if [[ -n "$FALLBACK_SOURCE_CLAUDE_HOME" ]]; then
    warn "No Claude credentials found (checked ${DEFAULT_SOURCE_CLAUDE_HOME}/.claude and ${FALLBACK_SOURCE_CLAUDE_HOME}/.claude); continuing without Claude credential copy"
  else
    warn "No Claude credentials found under ${DEFAULT_SOURCE_CLAUDE_HOME}/.claude; continuing without Claude credential copy"
  fi
  return 1
}

# Auto-refresh the Claude OAuth token in SOURCE_CREDENTIALS_FILE when it is
# within OAUTH_REFRESH_THRESHOLD_SECONDS of expiry. Safe by design: every failure
# mode falls through with a warn and the existing token is copied unchanged, so
# this function cannot block user provisioning.
refresh_claude_oauth_if_expiring() {
  local creds_file="${SOURCE_CREDENTIALS_FILE:-}"
  local now_s expires_at_ms remaining_s refresh_token
  local response_file http_code new_access new_refresh expires_in
  local new_expires_at_ms tmp_creds

  if [[ -z "$creds_file" || ! -f "$creds_file" ]]; then
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    warn "jq or curl missing; skipping Claude OAuth auto-refresh"
    return 0
  fi

  expires_at_ms="$(jq -r '.claudeAiOauth.expiresAt // empty' "$creds_file" 2>/dev/null || true)"
  if [[ -z "$expires_at_ms" || "$expires_at_ms" == "null" ]]; then
    return 0
  fi
  if ! [[ "$expires_at_ms" =~ ^[0-9]+$ ]]; then
    warn "Claude expiresAt is not numeric; skipping auto-refresh"
    return 0
  fi

  now_s="$(date +%s)"
  remaining_s=$(( (expires_at_ms / 1000) - now_s ))

  if [[ "$remaining_s" -gt "$OAUTH_REFRESH_THRESHOLD_SECONDS" ]]; then
    log "Claude token has $((remaining_s / 60))m remaining; no refresh needed"
    return 0
  fi

  refresh_token="$(jq -r '.claudeAiOauth.refreshToken // empty' "$creds_file" 2>/dev/null || true)"
  if [[ -z "$refresh_token" || "$refresh_token" == "null" ]]; then
    warn "Claude credentials missing refreshToken; cannot auto-refresh (${remaining_s}s remaining)"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: would refresh Claude OAuth token (${remaining_s}s remaining; threshold ${OAUTH_REFRESH_THRESHOLD_SECONDS}s)"
    return 0
  fi

  log "Claude token has ${remaining_s}s remaining; refreshing via ${CLAUDE_OAUTH_TOKEN_URL}"

  response_file="$(mktemp)"
  http_code="$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    --max-time 30 \
    --request POST "$CLAUDE_OAUTH_TOKEN_URL" \
    --header "Content-Type: application/json" \
    --data "$(jq -cn --arg rt "$refresh_token" --arg cid "$CLAUDE_OAUTH_CLIENT_ID" \
      '{grant_type: "refresh_token", refresh_token: $rt, client_id: $cid}')" \
    2>/dev/null || echo "000")"

  if [[ ! "$http_code" =~ ^2 ]]; then
    warn "Claude OAuth refresh failed (HTTP ${http_code}); continuing with existing token"
    rm -f "$response_file"
    return 0
  fi

  new_access="$(jq -r '.access_token // empty' "$response_file" 2>/dev/null || true)"
  new_refresh="$(jq -r '.refresh_token // empty' "$response_file" 2>/dev/null || true)"
  expires_in="$(jq -r '.expires_in // 0' "$response_file" 2>/dev/null || echo 0)"
  rm -f "$response_file"

  if [[ -z "$new_access" ]]; then
    warn "Claude OAuth refresh response missing access_token; continuing with existing token"
    return 0
  fi
  if ! [[ "$expires_in" =~ ^[0-9]+$ ]]; then
    expires_in=0
  fi

  new_expires_at_ms=$(( (now_s + expires_in) * 1000 ))

  tmp_creds="$(mktemp)"
  if ! jq --arg at "$new_access" \
          --arg rt "${new_refresh:-$refresh_token}" \
          --argjson ea "$new_expires_at_ms" \
          '.claudeAiOauth.accessToken = $at
           | .claudeAiOauth.refreshToken = $rt
           | .claudeAiOauth.expiresAt = $ea' \
          "$creds_file" > "$tmp_creds"; then
    warn "Failed to rewrite Claude credentials JSON; leaving source file unchanged"
    rm -f "$tmp_creds"
    return 0
  fi

  install -m 600 "$tmp_creds" "$creds_file"
  rm -f "$tmp_creds"

  if [[ "$expires_in" -gt 0 ]]; then
    log "Claude OAuth token refreshed (new lifetime: $((expires_in / 60))m)"
  else
    log "Claude OAuth token refreshed (unknown lifetime; server did not return expires_in)"
  fi
}

# Auto-refresh the Codex OAuth token in ${SOURCE_CODEX_DIR}/auth.json when the JWT
# access_token's exp claim is within OAUTH_REFRESH_THRESHOLD_SECONDS. Same
# safe-failure contract as the Claude variant.
refresh_codex_oauth_if_expiring() {
  local codex_auth_file="${SOURCE_CODEX_DIR}/auth.json"
  local access_token refresh_token id_token client_id
  local exp_s now_s remaining_s
  local response_file http_code new_access new_refresh new_id
  local tmp_auth refresh_iso

  if [[ ! -f "$codex_auth_file" ]]; then
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1 \
     || ! command -v curl >/dev/null 2>&1 \
     || ! command -v python3 >/dev/null 2>&1; then
    warn "jq, curl, or python3 missing; skipping Codex OAuth auto-refresh"
    return 0
  fi

  access_token="$(jq -r '.tokens.access_token // empty' "$codex_auth_file" 2>/dev/null || true)"
  refresh_token="$(jq -r '.tokens.refresh_token // empty' "$codex_auth_file" 2>/dev/null || true)"
  id_token="$(jq -r '.tokens.id_token // empty' "$codex_auth_file" 2>/dev/null || true)"

  if [[ -z "$access_token" || -z "$refresh_token" ]]; then
    return 0
  fi

  exp_s="$(python3 - "$access_token" <<'PY'
import base64, json, sys
token = sys.argv[1]
parts = token.split(".")
if len(parts) < 2:
    print(0)
    raise SystemExit(0)
payload = parts[1] + "=" * (-len(parts[1]) % 4)
try:
    data = json.loads(base64.urlsafe_b64decode(payload))
    print(int(data.get("exp") or 0))
except Exception:
    print(0)
PY
)"

  if ! [[ "$exp_s" =~ ^[0-9]+$ ]] || [[ "$exp_s" == "0" ]]; then
    warn "Unable to decode Codex access_token exp claim; skipping auto-refresh"
    return 0
  fi

  now_s="$(date +%s)"
  remaining_s=$((exp_s - now_s))

  if [[ "$remaining_s" -gt "$OAUTH_REFRESH_THRESHOLD_SECONDS" ]]; then
    log "Codex token has $((remaining_s / 60))m remaining; no refresh needed"
    return 0
  fi

  client_id=""
  if [[ -n "$id_token" ]]; then
    client_id="$(python3 - "$id_token" <<'PY'
import base64, json, sys
token = sys.argv[1]
parts = token.split(".")
if len(parts) < 2:
    print("")
    raise SystemExit(0)
payload = parts[1] + "=" * (-len(parts[1]) % 4)
try:
    data = json.loads(base64.urlsafe_b64decode(payload))
    aud = data.get("aud")
    if isinstance(aud, list) and aud:
        print(aud[0])
    elif isinstance(aud, str):
        print(aud)
    else:
        print("")
except Exception:
    print("")
PY
)"
  fi

  if [[ -z "$client_id" ]]; then
    warn "Could not derive Codex OAuth client_id from id_token; skipping auto-refresh"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: would refresh Codex OAuth token (${remaining_s}s remaining; threshold ${OAUTH_REFRESH_THRESHOLD_SECONDS}s)"
    return 0
  fi

  log "Codex token has ${remaining_s}s remaining; refreshing via ${CODEX_OAUTH_TOKEN_URL}"

  response_file="$(mktemp)"
  http_code="$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    --max-time 30 \
    --request POST "$CODEX_OAUTH_TOKEN_URL" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=${refresh_token}" \
    --data-urlencode "client_id=${client_id}" \
    2>/dev/null || echo "000")"

  if [[ ! "$http_code" =~ ^2 ]]; then
    warn "Codex OAuth refresh failed (HTTP ${http_code}); continuing with existing token"
    rm -f "$response_file"
    return 0
  fi

  new_access="$(jq -r '.access_token // empty' "$response_file" 2>/dev/null || true)"
  new_refresh="$(jq -r '.refresh_token // empty' "$response_file" 2>/dev/null || true)"
  new_id="$(jq -r '.id_token // empty' "$response_file" 2>/dev/null || true)"
  rm -f "$response_file"

  if [[ -z "$new_access" ]]; then
    warn "Codex OAuth refresh response missing access_token; continuing with existing token"
    return 0
  fi

  refresh_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp_auth="$(mktemp)"
  if ! jq --arg at "$new_access" \
          --arg rt "${new_refresh:-$refresh_token}" \
          --arg it "${new_id:-$id_token}" \
          --arg ts "$refresh_iso" \
          '.tokens.access_token = $at
           | .tokens.refresh_token = $rt
           | .tokens.id_token = $it
           | .last_refresh = $ts' \
          "$codex_auth_file" > "$tmp_auth"; then
    warn "Failed to rewrite Codex credentials JSON; leaving source file unchanged"
    rm -f "$tmp_auth"
    return 0
  fi

  install -m 600 "$tmp_auth" "$codex_auth_file"
  rm -f "$tmp_auth"

  log "Codex OAuth token refreshed"
}

check_credential_expiry() {
  local credentials_file="$1"
  local result=""
  local status=""
  local expires_at=""
  local remaining_seconds=""

  if [[ -z "$credentials_file" || ! -f "$credentials_file" ]]; then
    warn "Claude credential file not found; skipping expiry pre-flight check"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not available; skipping Claude credential expiry pre-flight check"
    return 0
  fi

  result="$(
    python3 - "$credentials_file" "$CREDENTIAL_EXPIRY_WARN_DAYS" <<'PY'
import datetime
import json
import sys
import time

path = sys.argv[1]
warn_days = int(sys.argv[2])

try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:  # pragma: no cover - shell entrypoint safeguard
    print(f"ERROR\t{exc}")
    raise SystemExit(0)

node = data
if isinstance(node, dict) and isinstance(node.get("claudeAiOauth"), dict):
    node = node["claudeAiOauth"]

expires_raw = None
if isinstance(node, dict):
    for key in ("expiresAt", "expires_at", "expiry", "expiration", "expires"):
        if key in node:
            expires_raw = node[key]
            break

if expires_raw is None:
    print("MISSING")
    raise SystemExit(0)

if not isinstance(expires_raw, (int, float)):
    print(f"UNSUPPORTED\t{type(expires_raw).__name__}")
    raise SystemExit(0)

expires_epoch = float(expires_raw)
if expires_epoch > 10**12:
    expires_epoch /= 1000.0

expires_at = datetime.datetime.fromtimestamp(expires_epoch, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
remaining_seconds = int(expires_epoch - time.time())

if remaining_seconds < 0:
    print(f"EXPIRED\t{expires_at}\t{remaining_seconds}")
elif remaining_seconds <= warn_days * 86400:
    print(f"SOON\t{expires_at}\t{remaining_seconds}")
else:
    print(f"OK\t{expires_at}\t{remaining_seconds}")
PY
  )"

  IFS=$'\t' read -r status expires_at remaining_seconds <<<"$result"

  case "$status" in
    OK)
      log "Claude credentials valid until ${expires_at}"
      ;;
    SOON)
      warn "Claude credentials expire soon at ${expires_at} (about $((remaining_seconds / 3600)) hours remaining)"
      ;;
    EXPIRED)
      warn "Claude credentials appear expired as of ${expires_at}; refresh them before relying on this user"
      ;;
    MISSING)
      warn "Claude credentials do not include an expiry field; skipping expiry status"
      ;;
    UNSUPPORTED)
      warn "Claude credentials use an unsupported expiry format; skipping expiry status"
      ;;
    ERROR)
      warn "Unable to inspect Claude credential expiry; skipping expiry status"
      ;;
  esac
}

copy_file_if_present() {
  local source_path="$1"
  local target_path="$2"

  if [ ! -f "$source_path" ]; then
    warn "Skipping missing file: $source_path"
    return 0
  fi

  run_cmd install -D -m 600 -o "$PROJECT_USER" -g "$PROJECT_USER" "$source_path" "$target_path"
  log "Copied $(basename "$source_path")"
}

ensure_secret_file() {
  local file_path="$1"
  local label="$2"
  local mode=""
  local group_digit=""
  local other_digit=""

  if [ ! -f "$file_path" ]; then
    die "$label not found: $file_path"
  fi
  if [ ! -r "$file_path" ]; then
    die "$label is not readable: $file_path"
  fi

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

copy_codex_config_if_present() {
  local source_path="$1"
  local target_path="$2"
  local tmp_config=""

  if [ ! -f "$source_path" ]; then
    warn "Skipping missing file: $source_path"
    return 0
  fi

  if ! grep -Eq '^[[:space:]]*(openai_api_key|experimental_bearer_token)[[:space:]]*=' "$source_path"; then
    copy_file_if_present "$source_path" "$target_path"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: would copy $(basename "$source_path") with inline secret fields removed"
    return 0
  fi

  tmp_config="$(mktemp)"
  grep -Ev '^[[:space:]]*(openai_api_key|experimental_bearer_token)[[:space:]]*=' "$source_path" > "$tmp_config"
  install -D -m 600 -o "$PROJECT_USER" -g "$PROJECT_USER" "$tmp_config" "$target_path"
  rm -f "$tmp_config"
  log "Copied $(basename "$source_path") with inline secret fields removed"
}

configure_codex_api_key_auth() {
  local target_path="${TARGET_HOME}/.npm-global/bin:${DISPATCH_NPM_GLOBAL_BIN}:${TARGET_PATH_BASE}"

  [ -n "$CODEX_API_KEY_FILE" ] || return 0
  ensure_secret_file "$CODEX_API_KEY_FILE" "Codex API key file"

  if ! command -v sudo >/dev/null 2>&1; then
    die "sudo is required to configure Codex API auth for ${PROJECT_USER}"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: would run codex login --with-api-key for ${PROJECT_USER} using the configured secret file"
    return 0
  fi

  if ! { sudo -u "$PROJECT_USER" env "HOME=$TARGET_HOME" "PATH=$target_path" \
       codex login --with-api-key >/dev/null; } < "$CODEX_API_KEY_FILE"; then
    die "codex login --with-api-key failed for ${PROJECT_USER}"
  fi

  run_cmd chown -R "$PROJECT_USER:$PROJECT_USER" "$TARGET_CODEX_DIR"
  log "Configured Codex API-key login for ${PROJECT_USER}"
}

copy_dir_contents_if_present() {
  local source_dir="$1"
  local target_dir="$2"

  if [ ! -d "$source_dir" ]; then
    warn "Skipping missing directory: $source_dir"
    return 0
  fi

  run_cmd mkdir -p "$target_dir"
  run_cmd cp -a "$source_dir"/. "$target_dir"/
  run_cmd chown -R "$PROJECT_USER:$PROJECT_USER" "$target_dir"
  log "Synced $(basename "$source_dir")/"
}

configure_git_identity() {
  local git_name="${GIT_USER_NAME:-}"
  local git_email="${GIT_USER_EMAIL:-}"
  local target_gitconfig="${TARGET_HOME}/.gitconfig"

  if ! command -v git >/dev/null 2>&1; then
    warn "git is not installed; skipping git identity bootstrap"
    return 0
  fi

  if [[ -z "$git_name" ]]; then
    git_name="$(git config --global --get user.name 2>/dev/null || true)"
  fi

  if [[ -z "$git_email" ]]; then
    git_email="$(git config --global --get user.email 2>/dev/null || true)"
  fi

  if [[ -z "$git_name" || -z "$git_email" ]]; then
    warn "Global git user.name/email not found; skipping git identity bootstrap for ${PROJECT_USER}"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: configure git identity for ${PROJECT_USER} (${git_name} <${git_email}>)"
    return 0
  fi

  git config --file "$target_gitconfig" user.name "$git_name"
  git config --file "$target_gitconfig" user.email "$git_email"
  chown "$PROJECT_USER:$PROJECT_USER" "$target_gitconfig"
  log "Configured git identity for ${PROJECT_USER}"
}

configure_gh_auth() {
  local github_token="${GITHUB_TOKEN:-}"
  local target_path="${TARGET_HOME}/.npm-global/bin:${DISPATCH_NPM_GLOBAL_BIN}:${TARGET_PATH_BASE}"
  local auth_ready=false

  if [[ -z "$github_token" ]]; then
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    warn "gh is not installed; skipping GitHub CLI auth bootstrap"
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    warn "sudo is not installed; skipping GitHub CLI auth bootstrap"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: would attempt gh auth and git credential setup for ${PROJECT_USER} using GITHUB_TOKEN"
    return 0
  fi

  if sudo -u "$PROJECT_USER" env -u GITHUB_TOKEN -u GH_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u GH_ENTERPRISE_TOKEN \
      "HOME=$TARGET_HOME" "PATH=$target_path" \
      gh auth status --hostname github.com >/dev/null 2>&1; then
    log "gh already authenticated for ${PROJECT_USER}"
    auth_ready=true
  elif printf '%s\n' "$github_token" | sudo -u "$PROJECT_USER" \
      env -u GITHUB_TOKEN -u GH_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u GH_ENTERPRISE_TOKEN \
      "HOME=$TARGET_HOME" "PATH=$target_path" \
      gh auth login --hostname github.com --with-token >/dev/null 2>&1; then
    log "Configured gh auth for ${PROJECT_USER} from GITHUB_TOKEN"
    auth_ready=true
  else
    warn "gh auth login failed for ${PROJECT_USER}"
  fi

  if [[ "$auth_ready" == true ]]; then
    if sudo -u "$PROJECT_USER" env -u GITHUB_TOKEN -u GH_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u GH_ENTERPRISE_TOKEN \
        "HOME=$TARGET_HOME" "PATH=$target_path" \
        gh auth setup-git --hostname github.com >/dev/null 2>&1; then
      log "Configured git credential helper for ${PROJECT_USER} via gh auth setup-git"
    else
      warn "gh auth setup-git failed for ${PROJECT_USER}; git push may still prompt for credentials"
    fi
  fi
}

test_oauth_refresh() {
  local target_path="${TARGET_HOME}/.npm-global/bin:${DISPATCH_NPM_GLOBAL_BIN}:${TARGET_PATH_BASE}"
  local smoke_prompt="${CLAUDE_AUTH_SMOKE_PROMPT:-Return OK.}"
  local smoke_output=""
  local first_error_line=""

  if [[ "$TEST_REFRESH" != true ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: skipping OAuth refresh test for ${PROJECT_USER}"
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    warn "sudo is not installed; cannot run OAuth refresh test for ${PROJECT_USER}"
    echo "[WARN] OAuth refresh test failed"
    return 0
  fi

  if smoke_output="$(sudo -u "$PROJECT_USER" env "HOME=$TARGET_HOME" "PATH=$target_path" \
      bash -c 'claude -p --permission-mode bypassPermissions --output-format json "$1"' bash "$smoke_prompt" 2>&1)"; then
    echo "[OK] OAuth refresh test passed"
  else
    if printf '%s\n' "$smoke_output" | grep -q 'Invalid authentication credentials'; then
      first_error_line="api_error_status=401: Invalid authentication credentials"
    else
      first_error_line="$(printf '%s\n' "$smoke_output" | sed -n '1p' | cut -c1-240)"
    fi
    if [[ -n "$first_error_line" ]]; then
      warn "Claude OAuth smoke test failed for ${PROJECT_USER}: ${first_error_line}"
    else
      warn "Claude OAuth smoke test failed for ${PROJECT_USER}"
    fi
    echo "[WARN] OAuth refresh test failed"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_NAME="${2:-}"
      shift 2
      ;;
    --source-user)
      SOURCE_CLAUDE_USER="${2:-}"
      shift 2
      ;;
    --codex-api-key-file)
      [ "$#" -ge 2 ] || die "missing value for --codex-api-key-file"
      CODEX_API_KEY_FILE="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --test-refresh)
      TEST_REFRESH=true
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

if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  die "Project name must match ^[a-z0-9][a-z0-9-]*$"
fi

resolve_source_claude_dir || true
refresh_claude_oauth_if_expiring
refresh_codex_oauth_if_expiring
check_credential_expiry "$SOURCE_CREDENTIALS_FILE"

PROJECT_USER="ccuser-${PROJECT_NAME}"
TARGET_HOME="/home/${PROJECT_USER}"
TARGET_CLAUDE_DIR="${TARGET_HOME}/.claude"
TARGET_PROJECT_LINK="${TARGET_HOME}/project"
PROJECT_REPO_DIR="${LOOP_ROOT}/${PROJECT_NAME}"
TARGET_CODEX_DIR="${TARGET_HOME}/.codex"
USER_CREATED=false

if id "$PROJECT_USER" >/dev/null 2>&1; then
  log "User already exists: $PROJECT_USER"
else
  log "Creating user: $PROJECT_USER"
  run_cmd useradd -m -s /bin/bash "$PROJECT_USER"
  USER_CREATED=true
fi

run_cmd install -d -m 700 -o "$PROJECT_USER" -g "$PROJECT_USER" "$TARGET_CLAUDE_DIR"

if [[ -n "$SOURCE_CLAUDE_DIR" ]]; then
  copy_file_if_present "${SOURCE_CLAUDE_DIR}/.credentials.json" "${TARGET_CLAUDE_DIR}/.credentials.json"
  copy_file_if_present "${SOURCE_CLAUDE_DIR}/settings.json" "${TARGET_CLAUDE_DIR}/settings.json"
  copy_file_if_present "${SOURCE_CLAUDE_DIR}/settings.local.json" "${TARGET_CLAUDE_DIR}/settings.local.json"
  copy_file_if_present "${SOURCE_CLAUDE_DIR}/mcp-needs-auth-cache.json" "${TARGET_CLAUDE_DIR}/mcp-needs-auth-cache.json"
  if [[ -n "$SOURCE_CLAUDE_HOME" ]]; then
    copy_file_if_present "${SOURCE_CLAUDE_HOME}/.claude.json" "${TARGET_HOME}/.claude.json"
  fi

  shopt -s nullglob
  SESSION_FILES=(
    "${SOURCE_CLAUDE_DIR}"/session*
    "${SOURCE_CLAUDE_DIR}"/*.session*
  )
  shopt -u nullglob

  if [ "${#SESSION_FILES[@]}" -eq 0 ]; then
    log "No top-level session files found in ${SOURCE_CLAUDE_DIR}"
  else
    for session_file in "${SESSION_FILES[@]}"; do
      if [ -f "$session_file" ]; then
        copy_file_if_present "$session_file" "${TARGET_CLAUDE_DIR}/$(basename "$session_file")"
      fi
    done
  fi

  copy_dir_contents_if_present "${SOURCE_CLAUDE_DIR}/sessions" "${TARGET_CLAUDE_DIR}/sessions"
  copy_dir_contents_if_present "${SOURCE_CLAUDE_DIR}/session-env" "${TARGET_CLAUDE_DIR}/session-env"

  if [ -f "${SOURCE_CLAUDE_DIR}/history.jsonl" ]; then
    copy_file_if_present "${SOURCE_CLAUDE_DIR}/history.jsonl" "${TARGET_CLAUDE_DIR}/history.jsonl"
  fi
fi

if [[ "$USER_CREATED" == true ]]; then
  configure_git_identity
fi

if [ -d "$SOURCE_CODEX_DIR" ]; then
  run_cmd install -d -m 700 -o "$PROJECT_USER" -g "$PROJECT_USER" "$TARGET_CODEX_DIR"
  copy_file_if_present "${SOURCE_CODEX_DIR}/auth.json" "${TARGET_CODEX_DIR}/auth.json"
  copy_codex_config_if_present "${SOURCE_CODEX_DIR}/config.toml" "${TARGET_CODEX_DIR}/config.toml"
  log "Codex credentials copied from ${SOURCE_CODEX_DIR}"
else
  warn "Source Codex directory not found: ${SOURCE_CODEX_DIR}; skipping Codex credential copy"
fi

configure_codex_api_key_auth

configure_gh_auth

if [ -d "$PROJECT_REPO_DIR" ]; then
  run_cmd ln -sfn "$PROJECT_REPO_DIR" "$TARGET_PROJECT_LINK"
  run_cmd chown -h "$PROJECT_USER:$PROJECT_USER" "$TARGET_PROJECT_LINK"
  log "Linked project directory: $TARGET_PROJECT_LINK -> $PROJECT_REPO_DIR"
else
  warn "Repo directory not present yet, skipping ${TARGET_PROJECT_LINK} symlink"
fi

run_cmd chown -R "$PROJECT_USER:$PROJECT_USER" "$TARGET_CLAUDE_DIR"
test_oauth_refresh

log "User ready: $PROJECT_USER"
