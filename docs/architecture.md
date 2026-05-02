# Architecture

Stan: Phase 2 SSOT, 2026-05-02.

Repo centralizuje dispatch stack, a aktywny chain używa już runtime paths
budowanych od `${DISPATCH_HOME}`.

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
  -> F3 / dispatch-loop-hardened.sh
  -> F1 / pre-flight + setup + dispatch
  -> worker branch + PR
  -> F2 / wait + CCC review + CCC merge
  -> final JSON summary
```

1. Operator pisze manifest i review prompt.
2. Orchestrator dispatchuje workera.
3. Worker robi zmiany i otwiera PR.
4. CCC zwraca `VERDICT: PASS|WARN|FAIL`.
5. Ten sam session_id jest wznawiany do merge.
6. Orchestrator zapisuje `MERGED_SHA`, cost i status.

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

## Co daje to repo

- jeden kanoniczny dom dla skryptów, testów, playbooka i promptów
- mniej szukania po VPS i disposable repos
- solidny fundament pod Phase 2, 3 i 4

To repo rozwiązuje problem source-of-truth. Kolejna faza ma rozwiązać pełną
runtime portability.
