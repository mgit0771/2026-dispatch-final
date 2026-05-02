#!/usr/bin/env bash
# pre-dispatch-overlay-v2.sh — superset of v1, addressing rollout-2 EFs.
# Author: opus-dispatcher-ma. Scope: own infra (D-0008).
# Usage: bash pre-dispatch-overlay-v2.sh PROJECT_SLUG

set -euo pipefail

: "${DISPATCH_HOME:?DISPATCH_HOME must be set}"

P="${1:?usage: $0 PROJECT_SLUG}"
U="ccuser-${P}"
LOOP_ROOT="${OVERLAY_LOOP_ROOT:-${DISPATCH_HOME}/repos}"
SOURCE_CLAUDE_HOME="${OVERLAY_SOURCE_CLAUDE_HOME:-${DISPATCH_HOME}}"
GITHUB_PAT_FILE="${OVERLAY_GITHUB_PAT_FILE:-${DISPATCH_HOME}/.config/github-pat}"
SOURCE_CODEX_DIR="${OVERLAY_SOURCE_CODEX_DIR:-${DISPATCH_HOME}/.codex}"
SOURCE_CODEX_CONFIG="${OVERLAY_SOURCE_CODEX_CONFIG:-${SOURCE_CODEX_DIR}/config.toml}"
REPO="${LOOP_ROOT}/${P}"

lookup_user_home() {
  local passwd_entry=""

  passwd_entry="$(getent passwd "$1" || true)"
  [ -n "$passwd_entry" ] || return 1
  printf '%s\n' "$passwd_entry" | cut -d: -f6
}

if ! id "$U" >/dev/null 2>&1; then echo "ERROR: user $U not found — run setup-user.sh first"; exit 1; fi
USER_HOME="$(lookup_user_home "$U" || true)"
[ -n "$USER_HOME" ] || USER_HOME="/home/$U"
TARGET_CLAUDE_CREDENTIALS="${USER_HOME}/.claude/.credentials.json"
SOURCE_CLAUDE_CREDENTIALS="${SOURCE_CLAUDE_HOME}/.claude/.credentials.json"
if [ ! -d "$REPO" ]; then echo "ERROR: repo $REPO not found — run setup-repo.sh first"; exit 1; fi

# v1 fixes (rollout-1 derived)
chown -R "$U:$U" "$REPO"
echo "[overlay-v2] chown $REPO -> $U"
if [ -f "$SOURCE_CLAUDE_CREDENTIALS" ]; then
  install -d -m 700 -o "$U" -g "$U" "${USER_HOME}/.claude"
  cp "$SOURCE_CLAUDE_CREDENTIALS" "$TARGET_CLAUDE_CREDENTIALS"
  chown "$U:$U" "$TARGET_CLAUDE_CREDENTIALS"
  chmod 600 "$TARGET_CLAUDE_CREDENTIALS"
  echo "[overlay-v2] copied Claude creds from ${SOURCE_CLAUDE_HOME} -> $U"
fi
if ! sudo -u "$U" env HOME="$USER_HOME" gh auth status >/dev/null 2>&1; then
  [ -r "$GITHUB_PAT_FILE" ] || { echo "ERROR: GitHub PAT file not readable: $GITHUB_PAT_FILE"; exit 1; }
  PAT="$(<"$GITHUB_PAT_FILE")"
  printf '%s\n' "$PAT" | sudo -u "$U" env HOME="$USER_HOME" gh auth login --with-token
  sudo -u "$U" env HOME="$USER_HOME" gh auth setup-git
  echo "[overlay-v2] gh auth login + setup-git"
fi

# v2 NEW (rollout-2 derived)
# EF-S7-M: open dispatcher-scoped Codex config for read so codex login under ccuser works
if [ -f "$SOURCE_CODEX_CONFIG" ]; then
  CURRENT_PERMS="$(stat -c %a "$SOURCE_CODEX_CONFIG")"
  if [ "$CURRENT_PERMS" != "644" ]; then
    chmod 644 "$SOURCE_CODEX_CONFIG"
    echo "[overlay-v2] chmod 644 ${SOURCE_CODEX_CONFIG} (was $CURRENT_PERMS)"
  fi
fi

# EF-S7-N: emit reminder for caller to use proper CWD
echo "[overlay-v2] REMINDER: dispatch-worker.sh MUST be invoked with CWD=$REPO"
echo "[overlay-v2] use:  bash -c \"cd $REPO && bash <PR7-dir>/scripts/dispatch-worker.sh ...\""

# Verify
echo "[overlay-v2] verify:"
if [ -f "$TARGET_CLAUDE_CREDENTIALS" ]; then
  if ! sudo -u "$U" env HOME="$USER_HOME" python3 -c "import json,time; d=json.load(open('$TARGET_CLAUDE_CREDENTIALS')); h=(d['claudeAiOauth']['expiresAt']/1000-time.time())/3600; print(f'  claude: {h:+.1f}h')"; then
    echo "  claude: unable to inspect ${TARGET_CLAUDE_CREDENTIALS}"
  fi
else
  echo "  claude: missing (${TARGET_CLAUDE_CREDENTIALS})"
fi
if ! sudo -u "$U" env HOME="$USER_HOME" gh auth status 2>&1 | head -1 | sed 's/^/  gh: /'; then
  echo "  gh: unavailable"
fi
if [ -f "$SOURCE_CODEX_CONFIG" ]; then
  echo "  codex config.toml perms: $(stat -c %a "$SOURCE_CODEX_CONFIG")"
else
  echo "  codex config.toml perms: missing"
fi
echo "[overlay-v2] done — $P ready for dispatch"
