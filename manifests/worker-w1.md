# Worker Session Manifest — w1 (ccc-ph2-501)

## Preamble (AE)
U1/U2/U5/S3/A5/A9.

## 1. Objective

Phase 2 z 4-fazowego SSOT planu: **refactor 4 production scripts** (`dispatch-pre.sh` + 3 hardened) z hardcoded `/root/...` paths na **parametric `${DISPATCH_HOME}`**, zgodnie z layoutem ustawionym przez `bootstrap.sh`. Cel: jeden dispatcher = jeden Linux user = jeden `${DISPATCH_HOME}`, izolowane multi-instance setupy.

## 2. Context

Phase 1 (poprzedni worker) skopiował scripts as-is z VPS do SSOT repo. Dzisiejszy stan w `mgit0771/2026-dispatch-final` `main`:

- `bootstrap.sh` już tworzy layout: `${DISPATCH_HOME}/{dispatch,repos,.codex-headless,.ccc-headless,logs,registries,.config}`
- Hardened scripts mają per-var env override pattern (`${DISPATCH_LOOP_LOOP_ROOT:-/root/2026-loop}` etc.) ale defaultami nadal hardcoded `/root/...` paths
- `dispatch-pre.sh` (NIE hardened) ma inline literal `/root/codex-headless/`, `/root/2026-loop/repo-${PROJECT}`, `/home/claudeuser/.claude/.credentials.json` — używana aktywnie przez hardened-loop Phase B

Phase 2 kończy ten rozjazd: defaulty derive się od `${DISPATCH_HOME}` (REQUIRED, no silent fallback). Per-var override pattern zostaje (operator może override pojedynczą zmienną).

Phase 3 (next) usuwa OAuth chain i przepina na Anthropic API key.
Phase 4 (next) testuje dwie równoległe instancje `dispatcher-foo` + `dispatcher-bar`.

## 3. Constraints

- Modify ONLY: `scripts/dispatch-pre.sh`, `scripts/dispatch-loop-hardened.sh`, `scripts/dispatch-review-merge-hardened.sh`, `scripts/dispatch-batch-hardened.sh`, `bootstrap.sh` (note removal), `tests/test-dispatch-{pre,loop,review-merge,batch}.sh` (only if assertions break post-refactor), `README.md` + `docs/architecture.md` (path references update if any)
- **NIE TYKAĆ**: `scripts/dispatch-loop.sh`, `scripts/dispatch-review-merge.sh`, `scripts/dispatch-batch.sh` (ORIGINALS = historical artifacts, untouched)
- **NIE TYKAĆ**: `CLAUDE_CREDENTIALS_FILE` path / OAuth check logic — to Phase 3
- Commit prefix: `refactor:`
- PR title: `refactor: parametric DISPATCH_HOME paths (Phase 2 of 4)`
- Bash style: `set -euo pipefail`, idempotent, `bash -n` + `shellcheck` clean
- `DISPATCH_HOME` MUST be set — top-level `: "${DISPATCH_HOME:?DISPATCH_HOME must be set; source bootstrap output or export manually}"` w każdym z 4 scripts

## 4. Expected outputs

### 4.1 Path mapping — old → new defaults

| Var | Old default | New default |
|---|---|---|
| `SCRIPTS_DIR` | `/root/2026-ccc-dispatcher/scripts` | `${DISPATCH_HOME}/dispatch/scripts` |
| `LOOP_ROOT` | `/root/2026-loop` | `${DISPATCH_HOME}/repos` |
| `CODEX_HEADLESS_ROOT` | `/root/codex-headless` | `${DISPATCH_HOME}/.codex-headless` |
| `CCC_HEADLESS_ROOT` | `/root/ccc-headless` | `${DISPATCH_HOME}/.ccc-headless` |
| `TEARDOWN_SCRIPT` | `/root/2026-loop/repo-comp-loop-env/scripts/teardown.sh` | `${DISPATCH_HOME}/dispatch/scripts/teardown.sh` (file będzie stworzony w Phase 4 — w Phase 2 just update path) |
| project repo path | `${LOOP_ROOT}/repo-${PROJECT}` | `${LOOP_ROOT}/${PROJECT}` (drop `repo-` prefix — nadmiarowe gdy LOOP_ROOT już jest `/repos`) |
| codex-headless per-worker | `/root/codex-headless/${PROJECT}/${WORKER_NAME}` | `${CODEX_HEADLESS_ROOT}/${PROJECT}/${WORKER_NAME}` |
| ccc-headless per-task | `/root/ccc-headless/${PROJECT}/...` | `${CCC_HEADLESS_ROOT}/${PROJECT}/...` |

### 4.2 `dispatch-pre.sh` (251 LOC)

Top-of-file (po `set -euo pipefail`):

```bash
: "${DISPATCH_HOME:?DISPATCH_HOME must be set (source bootstrap output or export manually)}"
SCRIPTS_DIR="${DISPATCH_PRE_SCRIPTS_DIR:-${DISPATCH_HOME}/dispatch/scripts}"
LOOP_ROOT="${DISPATCH_PRE_LOOP_ROOT:-${DISPATCH_HOME}/repos}"
CODEX_HEADLESS_ROOT="${DISPATCH_PRE_CODEX_HEADLESS_ROOT:-${DISPATCH_HOME}/.codex-headless}"
```

Replace inline:
- line 54 `/home/claudeuser/.claude/.credentials.json` — **LEAVE AS-IS** (Phase 3 target)
- line 58 `local dir="/root/codex-headless/${PROJECT}/${WORKER_NAME}"` → `local dir="${CODEX_HEADLESS_ROOT}/${PROJECT}/${WORKER_NAME}"`
- line 163 `repo_path="/root/2026-loop/repo-${PROJECT}"` → `repo_path="${LOOP_ROOT}/${PROJECT}"`
- line 208/213 error messages with `/root/codex-headless/` → use `${CODEX_HEADLESS_ROOT}/` literal interpolation

### 4.3 `dispatch-loop-hardened.sh` (309 LOC)

Top:

```bash
: "${DISPATCH_HOME:?DISPATCH_HOME must be set}"
SCRIPTS_DIR="${DISPATCH_LOOP_SCRIPTS_DIR:-${DISPATCH_HOME}/dispatch/scripts}"
LOOP_ROOT="${DISPATCH_LOOP_LOOP_ROOT:-${DISPATCH_HOME}/repos}"
TEARDOWN_SCRIPT="${DISPATCH_LOOP_TEARDOWN_SCRIPT:-${DISPATCH_HOME}/dispatch/scripts/teardown.sh}"
# CLAUDE_CREDENTIALS_FILE — Phase 3
```

Adjust any inline `${LOOP_ROOT}/repo-${PROJECT}` patterns → `${LOOP_ROOT}/${PROJECT}`.

### 4.4 `dispatch-review-merge-hardened.sh` (502 LOC)

Top similar to loop-hardened, plus `CODEX_HEADLESS_ROOT` since this script polls `/root/codex-headless/${PROJECT}/${WORKER_NAME}/final-*.txt`:

```bash
CODEX_HEADLESS_ROOT="${DISPATCH_REVIEW_MERGE_CODEX_HEADLESS_ROOT:-${DISPATCH_HOME}/.codex-headless}"
CCC_HEADLESS_ROOT="${DISPATCH_REVIEW_MERGE_CCC_HEADLESS_ROOT:-${DISPATCH_HOME}/.ccc-headless}"
```

Replace inline `/root/codex-headless/`, `/root/ccc-headless/`, `/root/2026-loop/repo-${PROJECT}` patterns z env-derived equivalents (preserve `${VAR}` interpolation in heredocs / printf strings).

### 4.5 `dispatch-batch-hardened.sh` (928 LOC)

Same pattern. Plus line 393 `printf 'cd /root/2026-loop/repo-%s\n' "$project"` → `printf 'cd %s/%s\n' "$LOOP_ROOT" "$project"`.

### 4.6 `bootstrap.sh` — minor update

`print_final()` ostatnia linia obecnie:
```
printf 'Phase 1 note: some legacy /root path defaults remain until Phase 2.\n'
```

→ usunąć (Phase 2 done) lub zamienić na:
```
printf 'Set DISPATCH_HOME=%s before invoking dispatch-* scripts (or source the env file).\n' "$DISPATCH_HOME"
```

Rozważ stworzyć `${DISPATCH_HOME}/.dispatchrc` w `init_dirs` z `export DISPATCH_HOME=...` (mode 644) — opcjonalne, zostaw jeśli wymaga ≤10 LOC.

### 4.7 `tests/`

Tests obecnie mockują wszystkie `${DISPATCH_*}` env vars i podają fake `--scripts-dir` / pass overrides przez env. Spodziewane: po refactor MUSI test setup eksportować `DISPATCH_HOME` (np. do mock dir), inaczej top-level guard `: "${DISPATCH_HOME:?...}"` ubije test.

Update każdego z 4 test files:
- Setup: `export DISPATCH_HOME="${tmpdir}/dispatcher-test"` + `mkdir -p "${DISPATCH_HOME}/{dispatch/scripts,repos,.codex-headless,.ccc-headless,logs,registries,.config}"`
- Update assertions: error messages with paths (np. `tests/test-dispatch-loop.sh:138` mock printf używa `/root/codex-headless/...` — zmień na `${DISPATCH_HOME}/.codex-headless/...` jeśli source error message się zmienił)
- Run: `bash -n` + execute every test → all PASS

### 4.8 `README.md` + `docs/architecture.md`

Update wzmianki o paths (np. README "Phase 1 note: some legacy paths..." — usunąć). Architecture.md może mieć diagram katalogów — zaktualizuj jeśli pokazuje `/root/...` paths.

## 5. Definition of Done

- [ ] `scripts/dispatch-pre.sh` — DISPATCH_HOME guard + parametric paths
- [ ] `scripts/dispatch-loop-hardened.sh` — DISPATCH_HOME guard + parametric paths
- [ ] `scripts/dispatch-review-merge-hardened.sh` — DISPATCH_HOME guard + parametric paths
- [ ] `scripts/dispatch-batch-hardened.sh` — DISPATCH_HOME guard + parametric paths
- [ ] `bootstrap.sh` — print_final note updated
- [ ] All 4 tests updated to export DISPATCH_HOME + mock layout
- [ ] `bash -n` clean: bootstrap.sh, all 4 modified scripts, all 4 tests
- [ ] `shellcheck` clean: 4 modified scripts (informational warnings OK, no errors)
- [ ] All 4 tests PASS post-refactor (`bash tests/test-dispatch-*.sh`)
- [ ] `grep -nE '/root/(2026-(ccc|loop)|codex-headless|ccc-headless)' scripts/dispatch-pre.sh scripts/*-hardened.sh` returns **empty** (zero hardcoded `/root/` paths in modified files; originals untouched OK)
- [ ] README + architecture.md path references updated
- [ ] Commit prefix `refactor:`
- [ ] PR otwarty z PR title `refactor: parametric DISPATCH_HOME paths (Phase 2 of 4)`
- [ ] Final report

## 6. Materials

- Disposable build repo: `${WORKER_REPO_PATH}` (worker checkout already prepped przez F1)
- SSOT main HEAD: `bf65c21a` (Phase 1 merge)
- Bootstrap path layout source of truth: `bootstrap.sh:set_paths()` + `init_dirs()`
- Scripts (active production chain): pre.sh (251 LOC) + 3 hardened (309 + 502 + 928 LOC)
- Backup reference (jeśli potrzebne): `/root/2026-ccc-dispatcher/scripts/` na VPS = current stan przed Phase 2

## 7. Open questions

- Czy stworzyć `.dispatchrc` w bootstrap.sh? **Optional, ≤10 LOC OK; skip jeśli zwiększa scope.**
- Czy worker ma stworzyć stub `scripts/teardown.sh` żeby `TEARDOWN_SCRIPT` path nie wskazywał na nieistniejący plik? **NIE — Phase 4 dostarczy. W Phase 2 path może być valid-looking ale `teardown=0` default zostaje.**
- POLSKI w docs (zgodnie z handoff style).

---

## Final report
**Status:** [DONE/BLOCKED]
**Commit SHA:** [fills]
**PR URL:** [fills]
**Lines changed:** [total fills]
**Files modified:** [count]
**Decision:** [krótko]
**Blocked:** [none / opis]
