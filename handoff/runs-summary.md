# Runs Summary — R1 to R8

Skrót najważniejszych runów, żeby nowy operator nie musiał od razu czytać
całego pakietu handoff.

## R1 + R2 — 2026-04-30 / 2026-05-01

Pierwszy własny E2E ownera:

- 1 doc-only worker
- multi-turn CCC review -> merge w tej samej sesji
- wall około `35 min`
- koszt około `~$2-3`
- outcome: sukces, 1 PR zmergowany

Kluczowe learnings:

- `claude --resume` jest CWD-sensitive (`B25`)
- manifest musi mieć ścieżkę absolutną (`B26`)
- literal PAT w manifeście zablokuje push (`B27`)

Primary source:

- full log w external handoff: `runs/run-1-2-2026-04-30-doc-only-multiturn.md`

## R3 — 2026-05-01

Parallel batch pattern:

- 3 workerów równolegle
- batch CCC review i batch CCC merge
- wall około `23 min`
- 1 manual intervention
- outcome: sukces, economics potwierdzone

Najważniejszy wniosek:

- batch CCC jest wyraźnie tańszy i szybszy od sekwencyjnego single flow

Primary source:

- full log: `runs/run-3-2026-05-01-parallel-batch.md`

## R4 — 2026-05-01

F1 build + livetest:

- zbudowano `dispatch-pre.sh`
- potem live przetestowano go end-to-end
- outcome: sukces
- nowe odkrycie: `B29` slug length / POSIX user limit

Znaczenie:

- pierwszy raz pipeline został użyty do budowy własnej automatyzacji dispatchu

Primary source:

- full log: `runs/run-4-2026-05-01-F1-build.md`

## R5 — 2026-05-01

F2 build + chain test:

- zbudowano `dispatch-review-merge.sh`
- live chain: F1 -> worker -> F2 -> merge
- outcome: merge na GitHub poprawny, ale parser F2 się wyłożył na końcu
- nowe odkrycie: `B30` multi-line JSON parse fragility

Znaczenie:

- pipeline działał end-to-end, ale F2 wymagał recovery / hardeningu

Primary source:

- full log: `runs/run-5-2026-05-01-F2-build-chain.md`

## R6 — 2026-05-01

F3 build + single-command live test:

- zbudowano `dispatch-loop.sh`
- owner dostał 1 command -> merged PR + JSON summary
- outcome: sukces
- B30 recovery został sprawdzony live i zadziałał

Znaczenie:

- osiągnięto praktyczne `single command` dla 1 workera
- owner->PR automation doszła do około `80%`

Primary source:

- full log: `runs/run-6-2026-05-01-F3-build.md`

## R7 — 2026-05-01

F4 batch orchestrator build:

- artifact repo potwierdzony: `mgit0771/CCC-F4-BLD-20260501`
- README artefaktu opisuje flow:
  `N manifests -> N parallel workers -> batch CCC review -> batch CCC merge`
- następny artifact (`CCC-HD1-501-20260502`) mówi wprost:
  `F1-F4 zbudowane R4-R7 (LIVE-validated)`

Ważne:

- pełny run note R7 nie jest vendored w `ccc-dispatcher-handoff/`
- ten wpis opiera się na chain of evidence z repo artefaktu i R8 manifestu

## R8 — 2026-05-02

Codex audit hardening pass:

- artifact repo: `mgit0771/CCC-HD1-501-20260502`
- powstały:
  - `dispatch-review-merge-hardened.sh`
  - `dispatch-loop-hardened.sh`
  - `dispatch-batch-hardened.sh`
- zakres: 7 fixów po audycie F2/F3/F4
- outcome: hardened runtime copies stały się aktualnym kanonicznym zestawem na VPS

Najważniejsze fixy:

- `FAIL` nie może auto-merge'ować
- fallback SHA nie może zgłaszać fałszywego sukcesu
- per-project credential checks muszą być zgodne z real userem
- diagnostics i parsery muszą być bardziej jawne

Evidence:

- repo `CCC-HD1-501-20260502`
- obecne VPS copies w `/root/2026-ccc-dispatcher/scripts/` mają mtime `2026-05-02 11:01 UTC`

## Operator takeaway

- R1-R3 udowodniły economics i multi-turn / batch patterns
- R4-R6 zbudowały F1/F2/F3 w recursive dispatch loop
- R7 dołożył batch orchestrator F4
- R8 zahartował F2/F3/F4 po audycie

To repo Phase 1 zbiera wynik tych ośmiu runów w jednym miejscu.
