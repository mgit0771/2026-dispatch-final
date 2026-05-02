# Worker Session Manifest — w1 (ccc-ph4a-501)

## Preamble (AE)
U1/U2/U5/S3/A5/A9.

## 1. Objective

Phase 4a: **gap fix** (Phase 1 oversight) — skopiować + parametrize 4 ostatnie production scripts brakujących w SSOT repo. Te helpery są dependency dla `dispatch-pre.sh` Phase 0 pre-flight (linia 81-86 sprawdza obecność wszystkich 4) i bez nich bootstrap-bazowany dispatcher failuje.

Phase 4 LIVE parallel test (`dispatcher-test1` + `dispatcher-test2`) wymaga że SSOT jest **truly self-contained** — wszystko żyje w jednym repo, bootstrap-bazowany dispatcher pobiera + ma wszystko.

## 2. Context

Stan po Phase 3 (main HEAD `490e1979`):
- `scripts/` w SSOT zawiera 8 plików (4 originals + 3 hardened + ccc-headless-task.sh)
- Dispatch chain runtime używa też 4 helperów które żyją na VPS w 2 różnych katalogach:
  - `/root/2026-opus-dispatcher-ma/scripts/pre-dispatch-overlay-v2.sh` (49 LOC)
  - `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/setup-repo.sh` (305 LOC)
  - `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/setup-user.sh` (836 LOC)
  - `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/dispatch-worker.sh` (1334 LOC)
- `dispatch-pre.sh:81-86` (po Phase 3) wymaga: `${SCRIPTS_DIR}/pre-dispatch-overlay-v2.sh` executable + `${SCRIPTS_DIR}/{setup-repo,setup-user,dispatch-worker}.sh` present + dispatch-worker advertises `--backend headless`

Phase 4 (LIVE parallel test) jest blocked dopóki te 4 nie są w SSOT z parametric paths.

## 3. Constraints

- Modify ONLY: `scripts/{pre-dispatch-overlay-v2,setup-repo,setup-user,dispatch-worker}.sh` (4 NEW files), opcjonalnie `README.md` + `docs/architecture.md` (note coverage), opcjonalnie `tests/` if helpers have own test fixtures
- **NIE TYKAĆ**: 8 istniejących `scripts/*.sh`, `bootstrap.sh`
- Commit prefix: `feat:`
- PR title: `feat: consolidate dispatch helpers (overlay/setup/worker) into SSOT (Phase 4a)`
- Bash style: `set -euo pipefail`, `bash -n` + `shellcheck` clean (warnings OK)

## 4. Expected outputs

### 4.1 Strategy

Każdy z 4 plików: **kopiuj as-is** z VPS source, NASTĘPNIE refactor wg pattern Phase 2:
- Top-level guard: `: "${DISPATCH_HOME:?DISPATCH_HOME must be set}"` po `set -euo pipefail`
- Hardcoded paths → DISPATCH_HOME-derived defaults z env override pattern

### 4.2 `scripts/pre-dispatch-overlay-v2.sh` (49 LOC)

Source: `/root/2026-opus-dispatcher-ma/scripts/pre-dispatch-overlay-v2.sh`

Hardcoded path:
- `REPO="/root/2026-loop/repo-${P}"` (line 9)

Refactor:
```bash
LOOP_ROOT="${OVERLAY_LOOP_ROOT:-${DISPATCH_HOME}/repos}"
REPO="${LOOP_ROOT}/${P}"   # drop "repo-" prefix per Phase 2 convention
```

### 4.3 `scripts/setup-repo.sh` (305 LOC)

Source: `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/setup-repo.sh`

Hardcoded paths (from grep):
- Line 17 docstring: `/root/2026-loop/repo-${project}/` → update tekst
- Line 257: `TARGET_DIR="/root/2026-loop/repo-${PROJECT_NAME}"` → `TARGET_DIR="${LOOP_ROOT}/${PROJECT_NAME}"`
- Line 263: `run_cmd mkdir -p /root/2026-loop` → `run_cmd mkdir -p "${LOOP_ROOT}"`

Top env:
```bash
LOOP_ROOT="${SETUP_REPO_LOOP_ROOT:-${DISPATCH_HOME}/repos}"
```

### 4.4 `scripts/setup-user.sh` (836 LOC)

Source: `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/setup-user.sh`

Hardcoded path:
- Line 759: `PROJECT_REPO_DIR="/root/2026-loop/repo-${PROJECT_NAME}"` → `PROJECT_REPO_DIR="${LOOP_ROOT}/${PROJECT_NAME}"`

Top env:
```bash
LOOP_ROOT="${SETUP_USER_LOOP_ROOT:-${DISPATCH_HOME}/repos}"
```

Skanuj cały plik na inne hardcoded `/root/...` paths i sparametryzuj similarly. **Pełny grep:**
```
grep -nE '/root/(2026-(ccc|loop|opus)|codex-headless|ccc-headless|home/(claudeuser|codexuser))' scripts/setup-user.sh
```
Powinien returnować empty po refactor (tylko `${DISPATCH_HOME}/`/`${LOOP_ROOT}/` etc.).

### 4.5 `scripts/dispatch-worker.sh` (1334 LOC)

Source: `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/dispatch-worker.sh`

Hardcoded path (from grep):
- Line 891: `HEADLESS_OUTPUT_DIR="${HEADLESS_OUTPUT_DIR:-/root/codex-headless/${PROJECT}/${WORKER_NAME}}"` → `HEADLESS_OUTPUT_DIR="${HEADLESS_OUTPUT_DIR:-${CODEX_HEADLESS_ROOT}/${PROJECT}/${WORKER_NAME}}"`

Top env:
```bash
CODEX_HEADLESS_ROOT="${DISPATCH_WORKER_CODEX_HEADLESS_ROOT:-${DISPATCH_HOME}/.codex-headless}"
```

**MUST PRESERVE**: `--backend headless` flag advertisement (dispatch-pre.sh:85-86 grep check). Dodatkowy hardcoded paths zidentyfikowane przez worker — sparametryzuj z `${DISPATCH_HOME}/`-derived defaults.

### 4.6 `tests/`

Te 4 scripts NIE mają dedicated tests obecnie. Worker MOŻE dodać minimalny smoke test dla każdego (`bash -n` + `--help` smoke), ale to opcjonalne. **Minimum: bash -n + shellcheck clean dla każdego z 4.**

### 4.7 `README.md` + `docs/architecture.md`

- README: zaktualizuj wzmianki o `scripts/` (8 → 12 plików), pokaż pełen production chain
- architecture: update flow diagram żeby pokazać helpers (overlay → setup-repo → setup-user → dispatch-worker)

## 5. Definition of Done

- [ ] `scripts/pre-dispatch-overlay-v2.sh` — copy + parametric LOOP_ROOT
- [ ] `scripts/setup-repo.sh` — copy + parametric LOOP_ROOT
- [ ] `scripts/setup-user.sh` — copy + parametric LOOP_ROOT (+ inne paths jeśli znalezione)
- [ ] `scripts/dispatch-worker.sh` — copy + parametric CODEX_HEADLESS_ROOT (+ inne)
- [ ] All 4 files chmod 755 (executable)
- [ ] `bash -n` clean: 4 scripts
- [ ] `shellcheck` clean: 4 scripts (warnings OK)
- [ ] `dispatch-worker.sh` zachowuje `--backend headless` advertisement (sprawdź z `grep -E '\-\-backend.*headless|headless.*\-\-backend' scripts/dispatch-worker.sh`)
- [ ] `grep -nE '/root/(2026-(ccc|loop|opus)|codex-headless|ccc-headless)' scripts/{pre-dispatch-overlay-v2,setup-repo,setup-user,dispatch-worker}.sh` returns **empty**
- [ ] Każdy z 4 scripts ma top-level `: "${DISPATCH_HOME:?...}"` guard
- [ ] Commit prefix `feat:`
- [ ] PR otwarty z required title
- [ ] Final report

## 6. Materials

- Disposable build repo: `${WORKER_REPO_PATH}` (worker checkout already prepped)
- SSOT main HEAD: `490e1979` (Phase 3 merge)
- Source files na VPS dostępne via `cat`:
  - `/root/2026-opus-dispatcher-ma/scripts/pre-dispatch-overlay-v2.sh`
  - `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/setup-repo.sh`
  - `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/setup-user.sh`
  - `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/dispatch-worker.sh`

## 7. Open questions

- Test fixtures dla 4 nowych scripts: **opcjonalne**, scope cut do bash -n + shellcheck OK.
- `setup-user.sh` 836 LOC — może ma więcej hardcoded paths niż grep pokazał. Worker scan pełny + parametrize wszystko spójnie.
- POLSKI w docs.

---

## Final report
**Status:** [DONE/BLOCKED]
**Commit SHA:** [fills]
**PR URL:** [fills]
**Lines added:** [total fills]
**New files:** [count]
**Decision:** [krótko]
**Blocked:** [none / opis]
