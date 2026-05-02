# Worker Session Manifest — w1 (ccc-ph3-501)

## Preamble (AE)
U1/U2/U5/S3/A5/A9.

## 1. Objective

Phase 3 z 4-fazowego SSOT planu. **Dwa cele połączone:**

A. **Gap fix (Phase 1 oversight)**: Skopiować `ccc-headless-task.sh` (367 LOC, na VPS w `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/`) do `scripts/` w SSOT repo. Bez tego pliku bootstrap-bazowany dispatcher failuje na `[ -f "${SCRIPTS_DIR}/ccc-headless-task.sh" ] || die 1` w F2-h Phase 8.

B. **Anthropic API migration**: Zastąpić `claudeuser` OAuth chain (TTL-based credentials) na stateless `ANTHROPIC_API_KEY` z `${DISPATCH_HOME}/.config/anthropic-api-key`. Bootstrap.sh już deploy-uje ten plik (mode 600 owned by dispatcher) — ten worker zmienia call sites w 4+1 scripts.

## 2. Context

Stan po Phase 2 (main HEAD `b11eb25`):
- 4 production scripts (`dispatch-pre.sh`, `dispatch-loop-hardened.sh`, `dispatch-review-merge-hardened.sh`, `dispatch-batch-hardened.sh`) używają parametric `${DISPATCH_HOME}` paths
- Pre-flight checks robią `claude_hours()` parsing `/home/claudeuser/.claude/.credentials.json` (OAuth TTL > 1h)
- F2-h Phase 9 merge i F4-h Phase X merge wywołują `claude -p --resume` przez `sudo -u "$PROJECT_USER" env HOME=... PATH=... bash -c "claude -p ..."` (claude reads OAuth z `/home/${PROJECT_USER}/.claude/.credentials.json`)
- F2-h Phase 8 review wywołuje `${SCRIPTS_DIR}/ccc-headless-task.sh` — ALE TEN PLIK NIE ISTNIEJE W SSOT REPO (Phase 1 worker go nie skopiował, bo żył w innym katalogu na VPS)

Phase 4 (next) test parallel dispatcher-foo + dispatcher-bar = wymaga że bootstrap dispatcher działa w pełni samowystarczalnie (= wszystkie 5 scripts w `${DISPATCH_HOME}/dispatch/scripts/` + API key w `${DISPATCH_HOME}/.config/`).

## 3. Constraints

- Modify ONLY: `scripts/ccc-headless-task.sh` (NEW — copy + refactor), `scripts/dispatch-pre.sh`, `scripts/dispatch-loop-hardened.sh`, `scripts/dispatch-review-merge-hardened.sh`, `scripts/dispatch-batch-hardened.sh`, `tests/test-*.sh` (fixture update), `README.md` + `docs/architecture.md` (notes update)
- **NIE TYKAĆ**: `scripts/dispatch-loop.sh`, `scripts/dispatch-review-merge.sh`, `scripts/dispatch-batch.sh` (originals)
- **NIE TYKAĆ**: `bootstrap.sh` — już deploy-uje API key (mode 600, `${DISPATCH_HOME}/.config/anthropic-api-key`)
- Commit prefix: `refactor:`
- PR title: `refactor: Anthropic API migration + ccc-headless-task consolidation (Phase 3 of 4)`
- Bash: `set -euo pipefail`, `bash -n` + `shellcheck` clean
- **Security**: API key NIE pisz na disk pod `/home/${PROJECT_USER}/`. Pass via env z dispatcher (root) → sudo -u ${PROJECT_USER} env ANTHROPIC_API_KEY="$key" ... bash -c. Key fileowsko żyje TYLKO w `${DISPATCH_HOME}/.config/anthropic-api-key` (owned by dispatcher).

## 4. Expected outputs

### 4.1 NEW: `scripts/ccc-headless-task.sh`

Source: `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/ccc-headless-task.sh` (367 LOC). Skopiować do SSOT `scripts/ccc-headless-task.sh`, następnie zrobić następujące zmiany:

a. **Top-level guard** (po `set -euo pipefail`):
```bash
: "${DISPATCH_HOME:?DISPATCH_HOME must be set}"
ANTHROPIC_KEY_FILE="${CCC_HEADLESS_ANTHROPIC_KEY_FILE:-${DISPATCH_HOME}/.config/anthropic-api-key}"
```

b. **Replace hardcoded paths** (line ~8-9):
```bash
BASE_DIR="/root/2026-loop"          # OLD
LOG_ROOT="/root/ccc-headless"       # OLD
```
→
```bash
BASE_DIR="${CCC_HEADLESS_BASE_DIR:-${DISPATCH_HOME}/repos}"
LOG_ROOT="${CCC_HEADLESS_LOG_ROOT:-${DISPATCH_HOME}/.ccc-headless}"
```

Plus update `PROJECT_DIR="${BASE_DIR}/repo-${PROJECT}"` → `PROJECT_DIR="${BASE_DIR}/${PROJECT}"` (drop "repo-" prefix, zgodnie z Phase 2).

c. **Pre-flight API key check** (po validate args, przed user check):
```bash
[ -r "$ANTHROPIC_KEY_FILE" ] || die "Anthropic API key not readable: $ANTHROPIC_KEY_FILE"
[ "$(stat -c '%a' "$ANTHROPIC_KEY_FILE")" = "600" ] || die "Anthropic API key must have mode 600: $ANTHROPIC_KEY_FILE"
```

d. **API key injection** (line 197 metadata_command + line 241 sudo invocation):
```bash
# OLD:
sudo -u "$RUN_USER" env "HOME=$TARGET_HOME" "PATH=$TARGET_PATH" bash -lc "$command_text" bash "$PROJECT_DIR" "${claude_args[@]}"

# NEW:
local api_key
api_key="$(cat "$ANTHROPIC_KEY_FILE")"
sudo -u "$RUN_USER" env "HOME=$TARGET_HOME" "PATH=$TARGET_PATH" "ANTHROPIC_API_KEY=$api_key" bash -lc "$command_text" bash "$PROJECT_DIR" "${claude_args[@]}"
```

Note: `api_key` jest local variable + nigdy nie loguj/echo. NIE pisz do shell history (set +H if needed but probably overkill — this script is sudo-invoked).

### 4.2 `scripts/dispatch-pre.sh` (~278 LOC po Phase 2)

a. Top:
```bash
ANTHROPIC_KEY_FILE="${DISPATCH_PRE_ANTHROPIC_KEY_FILE:-${DISPATCH_HOME}/.config/anthropic-api-key}"
```

b. Remove function `claude_hours()` entirely (line 57-60 area).

c. Replace caller (line 83 area) `hours="$(claude_hours)" || die 1 ...`:
```bash
[ -r "$ANTHROPIC_KEY_FILE" ] || die 1 "Anthropic API key not readable: $ANTHROPIC_KEY_FILE"
[ "$(stat -c '%a' "$ANTHROPIC_KEY_FILE")" = "600" ] || die 1 "Anthropic API key must have mode 600: $ANTHROPIC_KEY_FILE"
```

d. Update Phase 0 log message: `claude=Xh` → `api_key=ok` (or similar; pre-flight hours metric retired).

### 4.3 `scripts/dispatch-loop-hardened.sh` (~310 LOC po Phase 2)

a. Top env: replace `CLAUDE_CREDENTIALS_FILE` ze `ANTHROPIC_KEY_FILE` (default `${DISPATCH_HOME}/.config/anthropic-api-key`).

b. Remove function `claude_hours()` (line ~44-50).

c. Replace caller (line ~145) check.

d. Update Phase A log message: `claude=Xh` → `api_key=ok`.

### 4.4 `scripts/dispatch-review-merge-hardened.sh` (~510 LOC po Phase 2)

a. Top env: replace `CLAUDE_CREDENTIALS_FILE` ze `ANTHROPIC_KEY_FILE`.

b. Remove `claude_hours()` (line ~95) i **`project_claude_hours()`** (line ~99) — per-project OAuth check unnecessary, jeden API key per dispatcher.

c. Replace callers (line ~264 + ~281).

d. Update Phase 0 log message: `claude=Xh, project_claude=Xh` → `api_key=ok`.

e. **Phase 9 merge invocation** (line ~415):
```bash
# OLD:
nohup sudo -u "$PROJECT_USER" env HOME="$TARGET_HOME" PATH="$TARGET_PATH" bash -c "$merge_cmd" >"$MERGE_LOG" 2>&1 &

# NEW:
local api_key
api_key="$(cat "$ANTHROPIC_KEY_FILE")"
nohup sudo -u "$PROJECT_USER" env HOME="$TARGET_HOME" PATH="$TARGET_PATH" ANTHROPIC_API_KEY="$api_key" bash -c "$merge_cmd" >"$MERGE_LOG" 2>&1 &
```

### 4.5 `scripts/dispatch-batch-hardened.sh` (~940 LOC po Phase 2)

Identyczne patterns jak F2-h:
a. Top env replace.
b. Remove `claude_hours()` + `project_claude_hours()`.
c. Replace callers (line ~387 worker auth check, ~630 main check).
d. **Phase 9 batch merge** (line ~766) — same pattern jak F2-h Phase 9.
e. Update log messages.

### 4.6 `tests/test-*.sh`

Update test fixtures:
- Setup: replace `mkdir -p ... /home/claudeuser/.claude/ + write fake .credentials.json` → `mkdir -p ${DISPATCH_HOME}/.config/ + write fake API key file mode 600`
- Mock API key value: dowolny placeholder NIE matching `sk-[A-Za-z0-9-]{20,}` (np. `mock-anth-test-key-12345` lub literal `<TEST_API_KEY>`); ≥20 chars dla mode check tylko
- Update assertions: instead `claudeuser credentials are unreadable` → `Anthropic API key not readable`

### 4.7 `README.md` + `docs/architecture.md`

- README: zmienić wzmianki o `claudeuser`/OAuth na "Anthropic API key (stateless)"
- architecture: update auth model section — single API key per dispatcher, no TTL, no `claudeuser` user

## 5. Definition of Done

- [ ] `scripts/ccc-headless-task.sh` — NEW, copied + refactored (~370 LOC + ~30 LOC change)
- [ ] `scripts/dispatch-pre.sh` — claude_hours removed, ANTHROPIC_KEY_FILE check
- [ ] `scripts/dispatch-loop-hardened.sh` — same
- [ ] `scripts/dispatch-review-merge-hardened.sh` — claude_hours + project_claude_hours removed, Phase 9 ANTHROPIC_API_KEY env injection
- [ ] `scripts/dispatch-batch-hardened.sh` — same
- [ ] `bash -n` clean: 5 scripts (4 modified + 1 new)
- [ ] `shellcheck` clean: 5 scripts (warnings OK, no errors)
- [ ] All 4 tests updated + PASS
- [ ] `grep -nE 'claudeuser|/home/claudeuser|claude_hours|CLAUDE_CREDENTIALS_FILE' scripts/dispatch-pre.sh scripts/dispatch-*-hardened.sh scripts/ccc-headless-task.sh` returns **empty** (zero OAuth references in modified scripts)
- [ ] `grep -nE 'ANTHROPIC_API_KEY|ANTHROPIC_KEY_FILE' scripts/...sh` shows expected refs (top env + check + env injection at merge sites)
- [ ] Commit prefix `refactor:`
- [ ] PR otwarty z required title
- [ ] Final report

## 6. Materials

- Disposable build repo: `${WORKER_REPO_PATH}` (worker checkout already prepped)
- SSOT main HEAD: `b11eb25` (Phase 2 merge)
- VPS source dla `ccc-headless-task.sh`: dostępne via `cat /root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/ccc-headless-task.sh` (worker ma sudo? jeśli nie → spr. czy worker user ma dostęp; alternative: copy przez ssh-key/proxy mechanism już w workspace)
- Bootstrap.sh layout (już ustawiony Phase 1+2): `${DISPATCH_HOME}/.config/anthropic-api-key` mode 600 owned by dispatcher-${ID}

## 7. Open questions

- API key access dla `ccuser-${PROJECT}` — pass via env (recommended, w manifest scope) vs copy do `/home/${PROJECT_USER}/.config/`. **Rekomendacja: env-only**, bo:
  - Mniej ścieżek do utrzymania
  - Key live tylko w jednym miejscu (DISPATCH_HOME)
  - Reduce risk of stale copies
- Czy zachować back-compat z OAuth (fallback to `claude_hours()` jeśli brak API key)? **NIE** — clean break, Phase 4 LIVE test wymaga API-only flow.
- POLSKI w docs (zgodnie z handoff style).

---

## Final report
**Status:** [DONE/BLOCKED]
**Commit SHA:** [fills]
**PR URL:** [fills]
**Lines changed:** [total fills]
**Files modified:** [count]
**New files:** [count]
**Decision:** [krótko]
**Blocked:** [none / opis]
