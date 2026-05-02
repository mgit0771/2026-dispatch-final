# Architecture

Stan: Phase 4a SSOT gap fix, 2026-05-02.

Repo centralizuje dispatch stack, a aktywny chain używa już runtime paths
budowanych od `${DISPATCH_HOME}`.

W Phase 4a do repo dochodzi pełny helper chain wymagany przez `dispatch-pre.sh`,
więc bootstrap-based dispatcher nie musi już dobierać skryptów z osobnych VPS
lokacji.

## 5 aktorów

```text
Operator
  |
  v
Owner / Orchestrator ----> Letta
  |                         ^
  v                         |
CCC ------------------------+
  |
  v
Worker -> GitHub PR / repo state
```

- `Operator` wybiera task, policy i uruchamia flow.
- `Owner / Orchestrator` steruje F1/F2/F3/F4 i zbiera artifacts.
- `CCC` robi review Turn 1 i merge Turn 2.
- `Worker` wykonuje pracę na branchu workera.
- `Letta` jest opcjonalną warstwą pamięci, nie jedynym source of truth.

## Headless first

Najważniejszy kierunek po dotychczasowych runach:

- TUI jest dobre do obserwacji.
- Headless jest lepszy do deterministycznego pipeline'u.

Powody:

- mniej zależności od tmux i paste semantics
- łatwiejsze logi, recovery i resume po session_id
- łatwiejsze parsowanie wyników
- niższy narzut operacyjny dla ownera

W praktyce:

- workerzy powinni działać headless
- CCC review/merge powinno być bounded i headless-first
- JSON jest formatem kanonicznym dla outputu

## Gdzie żyje state

State ma żyć w storage, nie tylko w procesie:

- repo git i branch workera
- final / log files
- JSONL registries
- session_id dla CCC i Codexa
- opcjonalnie Letta memory

To jest ważniejsze niż sam tmux session.

## Single-worker flow

```text
manifest
  -> dispatch-loop-hardened.sh
  -> dispatch-pre.sh
  -> setup-repo.sh
  -> setup-user.sh
  -> pre-dispatch-overlay-v2.sh
  -> dispatch-worker.sh --backend headless
  -> worker branch + PR
  -> dispatch-review-merge-hardened.sh
  -> final JSON summary
```

1. Operator pisze manifest i review prompt.
2. `dispatch-pre.sh` uruchamia kompletny setup i overlay z helperów w tym repo.
3. `dispatch-worker.sh` uruchamia workera headless i zapisuje artifacts pod
   `${DISPATCH_HOME}`.
4. Worker robi zmiany i otwiera PR.
5. CCC zwraca `VERDICT: PASS|WARN|FAIL`.
6. Ten sam session_id jest wznawiany do merge.
7. Orchestrator zapisuje `MERGED_SHA`, cost i status.

## Multi-turn CCC mechanics

CCC powinien działać jako dwa bounded turny w jednej sesji:

- Turn 1 -> review
- Turn 2 -> merge

To daje:

- reuse kontekstu
- niższy koszt przez cache hit
- mniejsze ryzyko rozjazdu między review i merge intent

Twarde reguły:

- resume musi być z właściwego `CWD`
- output ma być JSON / stream-json
- `FAIL` nie może przejść do auto-merge

## Model auth

Od Phase 3 aktywny chain nie używa już `claudeuser` ani OAuth TTL checks.

- jeden dispatcher ma jeden stateless `ANTHROPIC_API_KEY`
- klucz żyje tylko w `${DISPATCH_HOME}/.config/anthropic-api-key`
- plik musi być czytelny dla dispatchera i mieć mode `600`
- review / merge przekazują klucz dalej wyłącznie przez env
- worker users nie trzymają lokalnych kopii klucza pod `/home/ccuser-*`

To upraszcza bootstrap, eliminuje problem wygasających credentiali i zmniejsza
ryzyko stale copies.

## Model izolacji

### Phase 1

`bootstrap.sh` daje izolację organizacyjną:

- osobny user `dispatcher-<id>`
- osobny home / checkout
- osobne secret files
- osobne registries
- osobne katalogi logów i headless artifacts

To był fundament pod pełną parametryzację runtime paths w Phase 2.

### Phase 2

Aktywny chain (`dispatch-pre.sh` + hardened F2/F3/F4) ma teraz:

- `DISPATCH_HOME` jako required env guard
- defaulty `dispatch/scripts`, `repos`, `.codex-headless`, `.ccc-headless`,
  `logs`, `registries`, `.config` wyprowadzane z `${DISPATCH_HOME}`
- brak obowiązkowych odwołań do wspólnego host-global path w aktywnych skryptach

To daje docelowy model izolacji:

- osobne headless roots i registries dla każdego dispatchera
- dwa dispatchery mogą działać równolegle bez shared-state collisions

### Phase 3

Aktywny chain jest już auth-portable i bootstrap-complete:

- `ccc-headless-task.sh` jest częścią repo i używa `${DISPATCH_HOME}` defaults
- review / merge nie zależą od `/home/claudeuser/.claude/.credentials.json`
- dispatcher przenosi jeden Anthropic key przez env do procesów uruchamianych
  jako `ccuser-*`

## Co daje to repo

- jeden kanoniczny dom dla skryptów, testów, playbooka i promptów
- mniej szukania po VPS i disposable repos
- pełny production helper chain w jednym checkout
- solidny fundament pod live parallel test z bootstrap-only dispatchera

To repo rozwiązuje problem source-of-truth. Kolejna faza ma rozwiązać pełną
runtime portability.
