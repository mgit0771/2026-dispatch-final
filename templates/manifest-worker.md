# Worker Session Manifest — {{WORKER_NAME}} ({{PROJECT_SLUG}})

## Preamble

U1/U2/U5/S3/A5/A9.

## 1. Objective

Krótko i jednoznacznie:

- co worker ma dostarczyć
- w jakim repo / branch scope
- jaki artefakt końcowy ma powstać

Przykład:

- Zmodyfikować `docs/foo.md` i `scripts/bar.sh`
- Otworzyć PR z pełnym final report
- Nie wychodzić poza wskazany scope

## 2. Context

Stan wejściowy:

- repo: `{{OWNER}}/{{REPO}}`
- branch roboczy: `worker/{{PROJECT_SLUG}}-{{WORKER_NAME}}`
- problem biznesowy / techniczny:
- znane artefakty i źródła prawdy:
- co już zostało sprawdzone:

Jeśli są zależności zewnętrzne, wpisz je jawnie.

## 3. Constraints

- Modify ONLY: `{{ALLOWED_PATHS}}`
- Commit prefix: `{{COMMIT_PREFIX}}`
- PR title: `{{PR_TITLE}}`
- Bash / code style: `set -euo pipefail`, idempotent, bez secretów literalnych
- NIE wklejaj PAT / API key / tokenów do repo ani do manifestu

## 4. Expected outputs

Wypisz konkretnie:

- jakie pliki mają powstać lub zostać zmienione
- jakie testy / walidacje mają przejść
- jaki wynik użytkowy ma być osiągnięty

Format praktyczny:

- `path/to/file` — co ma zawierać
- `path/to/test` — co ma potwierdzić
- `README` / docs — co ma opisać

## 5. Definition of Done

- [ ] scope dowieziony
- [ ] testy / walidacje uruchomione
- [ ] commit z właściwym prefixem
- [ ] PR otwarty
- [ ] Final report uzupełniony

## 6. Materials

- Local repo path: `{{LOCAL_REPO_PATH}}`
- Source docs / repos:
- Sekrety tylko jako path references lub env var names

## 7. Open questions

- pytanie 1
- pytanie 2

Jeśli brak pytań:

- none

---

## Final report

**Status:** [DONE/BLOCKED]
**Commit SHA:** [fills]
**PR URL:** [fills]
**Lines:** [fills]
**Files created:** [fills]
**Decision:** [krótko]
**Blocked:** [none / opis]
