# CCC Merge Prompt Template

Użyj tego jako Turn 2 w TEJ SAMEJ sesji CCC po review.
Ten prompt zakłada, że verdict z Turn 1 już istnieje i merge jest autoryzowany.

## Inputs

- Project: `{{PROJECT}}`
- Repo path: `{{PROJECT_DIR}}`
- Worker branch: `worker/{{PROJECT}}-{{WORKER_NAME}}`
- Review verdict: `{{VERDICT}}`
- Merge commit message suffix: `merge: {{WORKER_NAME}} {{VERDICT}}`

## Instructions

Jesteś wznawiany w tej samej sesji CCC po Turn 1 review.

1. Przejdź do repo projektu.
2. Zsynchronizuj `main` bez merge commitów.
3. Wykonaj squash merge brancha workera.
4. Nie przenoś katalogu `manifests/` na `main`.
5. Pushnij `main`.
6. Usuń branch workera z origin.
7. Jeśli dowolny krok failuje, zatrzymaj się i zwróć status failure zamiast zgadywać.

## Suggested command sequence

```bash
cd {{PROJECT_DIR}}
git fetch origin
git checkout main
git pull origin main --ff-only
git merge --squash origin/worker/{{PROJECT}}-{{WORKER_NAME}}
git reset HEAD manifests/ 2>/dev/null || true
rm -rf manifests/ 2>/dev/null || true
git -c user.email='mg@fractals-ai.com' -c user.name='mgit0771' commit -m 'merge: {{WORKER_NAME}} {{VERDICT}}'
git push origin main
git push origin --delete worker/{{PROJECT}}-{{WORKER_NAME}}
```

## Required output markers

Po wykonaniu zwróć:

- `MERGE_STATUS: SUCCESS` albo `MERGE_STATUS: FAILED`
- `MERGED_SHA: <sha>` gdy sukces
- `MERGE_NOTES:` 1 krótka linia

## Safety

- Nie merge'uj, jeśli verdict z Turn 1 był `FAIL`
- Jeśli jest conflict albo fast-forward issue, zwróć `MERGE_STATUS: FAILED`
- Nie zamieniaj failure na "prawie sukces"
- Utrzymaj ten sam session context; nie traktuj tego jako fresh task
