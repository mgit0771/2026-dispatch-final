# Blockers — B1 to B30 condensed

Pełny katalog żyje w external handoff:
`mgit0771/2026-loop-final` branch `ccc-dispatcher`,
plik `ccc-dispatcher-handoff/03-BLOCKERS.md`.

Tu jest tylko skrót operacyjny.

## Transport / TUI

- `B1` CMD API ma timeout `60s` -> `nohup + poll`.
- `B3-B5` TUI / tmux były kruche -> headless jest bezpieczniejszy.
- `B7` watcher nie może patrzeć na sam tekst manifestu.
- `B24` shell expansion na VPS bywała niestabilna.

## Auth / credentials

- `B6` project user musi mieć działające `gh auth`.
- `B9-B11` OAuth i permy potrafiły rozwalić setup lub CCC headless.
- `B15`, `B18`, `B21`, `B28` pokazały, że auth trzeba sprawdzać per user,
  nie tylko globalnie.

## Repo / paths / ownership

- `B2` fetch spec musi widzieć więcej niż `main`.
- `B16-B17-B22` stale repo i złe ownership blokują review i merge.
- `B19` worker wymaga poprawnego `CWD`.
- `B25` `claude --resume` jest CWD-sensitive.
- `B26` manifest musi mieć ścieżkę absolutną.
- `B29` slug trzeba walidować przed `useradd`.

## JSON / CCC / process

- `B13` multi-turn CCC wymaga JSON, nie text.
- `B14` grep+regex na JSONL jest kruche.
- `B30` parser F2 nie radził sobie z multi-line `--verbose`.
- `B8` Comp nie może sam merge'ować zamiast CCC.
- `B20` worker potrafi pominąć Final report.
- `B27` literal PAT w manifeście słusznie blokuje push.

## Co z tego wynika dla SSOT

- Phase 1 centralizuje skrypty, testy i playbook.
- `bootstrap.sh` przygotowuje per-dispatcher home, sekrety i registries.
- Hardened F2/F3/F4 są preferowanymi entry pointami.
- Phase 2 ma usunąć legacy `/root/...` assumptions i domknąć izolację.
