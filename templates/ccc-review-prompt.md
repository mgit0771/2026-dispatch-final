# CCC Review Prompt Template

Użyj tego jako Turn 1 dla CCC review. Celem jest verdict i lista ryzyk,
bez wykonywania merge w tej turze.

## Inputs

- Project: `{{PROJECT}}`
- Repo path: `{{PROJECT_DIR}}`
- Target repo: `{{OWNER}}/{{REPO}}`
- Worker branch: `worker/{{PROJECT}}-{{WORKER_NAME}}`
- PR URL: `{{PR_URL}}`
- Task summary: `{{TASK_SUMMARY}}`
- Scope / DoD: `{{DOD_SUMMARY}}`

## Instructions

Pracujesz jako CCC pre-merge reviewer.

1. Sprawdź diff `origin/main...origin/worker/{{PROJECT}}-{{WORKER_NAME}}`.
2. Oceń poprawność, regresje, ryzyko merge, brakujące testy i zgodność z DoD.
3. Nie wykonuj merge w tej turze.
4. Zwróć wynik tak, aby pierwszy marker był parsowalny przez orchestrator.

## Required output

Pierwsza linia musi mieć dokładnie format:

`VERDICT: PASS`
albo
`VERDICT: WARN`
albo
`VERDICT: FAIL`

Potem zwróć:

- `RATIONALE:` 1 krótki akapit
- `FINDINGS:` lista problemów lub `none`
- `DOD:` pass / partial / fail
- `MERGE_READY:` yes / no
- `FOLLOW_UP:` opcjonalnie

## Verdict semantics

- `PASS` = bezpieczne do merge as-is
- `WARN` = merge możliwy, ale owner powinien znać ryzyka lub braki
- `FAIL` = nie merge'ować

## Review focus

- correctness > style
- security / secret hygiene > cosmetics
- missing tests > minor polish
- behavior regressions > refactor preference

## Safety

- Jeśli nie możesz zweryfikować krytycznej rzeczy, nie zgaduj -> daj `WARN` albo `FAIL`
- Jeśli widzisz literal secret, zawsze `FAIL`
- Jeśli worker pominął Final report albo DoD, odnotuj to jawnie
