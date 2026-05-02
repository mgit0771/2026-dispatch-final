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

---

## SSOT consolidation cycle — 2026-05-02

Po R8 owner przeprowadził 4-fazowy plan konsolidacji wszystkich rozproszonych
artefaktów w jedno repo `mgit0771/2026-dispatch-final`. Każda faza dispatch'owana
przez F3-h (single-command) z VPS, każda zmergowana po PASS verdict CCC review.

| Phase | Scope | Main HEAD | Cost CCC |
|---|---|---|---|
| 1 | repo structure + bootstrap.sh + copy 7 scripts + docs | `bf65c21a` | $0.42 |
| 2 | parametric `${DISPATCH_HOME}` paths in 4 active scripts | `b11eb25` | $0.79 |
| 3 | Anthropic API migration (drop OAuth) + ccc-headless-task in-repo | `490e1979` | $1.32 |
| 4a | gap fix — copy 4 helpers (overlay/setup-repo/user/dispatch-worker) | `bfa39c9` | $0.49 |

Phase 4 LIVE parallel test:

- bootstrap dwóch isolated dispatchers `test1` + `test2`
- każdy dispatch'ował tiny `hello.txt` worker do disposable repo
  (`CCC-PH4LT-T1-501`, `CCC-PH4LT-T2-501`)
- pierwsza CCC review FAIL'd (mój prompt za ostry — zignorował `manifests/worker-w1.md`
  artifact F1); relaunch z poprawionym prompt → oba PASS+merged
- isolation perfect: zero cross-contamination między `/home/dispatcher-test1`
  i `/home/dispatcher-test2`, oddzielne ccuser-* (uid 1018/1019), oddzielne
  `.codex-headless` / `.ccc-headless` / `repos`

Total SSOT cycle cost: ~$3.93 in CCC.

Demonstrated property: dowolny agent / operator może `git clone` + `bootstrap.sh`
+ run dispatch — wszystko self-contained, brak zewnętrznych zależności poza
sekretami (PAT/Anthropic/Codex keys).

Pending follow-ups (out of SSOT cycle scope):

- non-root dispatch invocation (`dispatch-pre.sh` Phase 0 nadal wymaga root)
- F2-h Phase 9 `MERGED_SHA` parser fragility w v2 relaunch case (cosmetic — merge succeeds)
- cleanup test resources gdy nie potrzebne
