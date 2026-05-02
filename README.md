# 2026-dispatch-final

CCC Dispatch Pipeline SSOT, Phase 1 of 4.

This repository centralizes the current dispatch stack in one place:

- orchestrator scripts
- copied shell tests
- operator playbook
- fresh-agent bootstrap prompt
- handoff pointers
- reusable templates
- `bootstrap.sh` for a new dispatcher account

## Phase 1 Status

As of 2026-05-02 this repo is the canonical home for the artifacts, but runtime
portability is not fully finished yet.

- `scripts/` are copied as-is from the VPS.
- `bootstrap.sh` prepares a per-dispatcher user, home, repo checkout, secret
  files, registries, and log directories.
- Hardened F2/F3/F4 variants are included because they are the current best
  runtime copies on the VPS.
- Some legacy `/root/...` assumptions still exist, mainly around F1. Full
  `${DISPATCH_HOME}` path refactor is Phase 2.

Practical meaning:

- current VPS / current environment: usable now
- clean-room portability to any host: next phase

## Quick Start

```bash
git clone https://github.com/mgit0771/2026-dispatch-final.git
cd 2026-dispatch-final

sudo bash ./bootstrap.sh \
  --instance-id alpha \
  --owner-pat-file /secure/github-pat.txt \
  --anthropic-key-file /secure/anthropic-api-key.txt \
  --codex-key-file /secure/openai-api-key.txt
```

Requirements:

- secret files must exist and have mode `600`
- bootstrap should run as `root` or passwordless `sudo`
- use `--dry-run` first if you only want validation

After bootstrap:

```bash
sudo -u dispatcher-alpha bash /home/dispatcher-alpha/dispatch/scripts/dispatch-loop-hardened.sh --help
```

## Repo Layout

```text
.
├── README.md
├── bootstrap.sh
├── scripts/
├── tests/
├── playbook/
├── templates/
├── agents/
├── handoff/
└── docs/
```

- `scripts/` -> F1/F2/F3/F4 originals plus hardened F2/F3/F4
- `tests/` -> copied shell tests from the VPS
- `playbook/` -> quick start, economics, decision rules, blocker summary
- `templates/` -> worker manifest and CCC prompt templates
- `agents/` -> fresh-agent cold-start prompt
- `handoff/` -> key ownership docs plus pointer to the full long-form package
- `docs/architecture.md` -> actors, flow, headless-first, isolation target

## Workflow

Nominal Phase 1 path:

1. Write a manifest from `templates/manifest-worker.md`.
2. Write CCC review and merge prompts from `templates/ccc-*.md`.
3. Run one of the orchestrators:
   - `scripts/dispatch-loop-hardened.sh` for one worker / one PR
   - `scripts/dispatch-batch-hardened.sh` for parallel workers / batch CCC
4. Worker opens PR(s).
5. CCC reviews in Turn 1 and merges in Turn 2 on the same session.
6. Operator reads the final JSON summary and archives the run.

## Cost Snapshot

From `playbook/cost-model.md`:

- single doc-only worker + multi-turn CCC: about `35 min`, `~$2-3`
- parallel 3 workers + batch CCC: about `23 min`, `~$3-5` total
- CCC cost per PR in R3 batch mode: about `70%` lower than single serial flow
- same-session CCC merge saved about `35-40%` vs a fresh Turn 2

Rule of thumb:

- 1 PR -> F3
- 2-5 similar PRs -> F4
- task too large for one turn -> multi-turn worker pattern

## Read Next

- `playbook/00-quick-start.md`
- `playbook/decision-framework.md`
- `playbook/blockers.md`
- `docs/architecture.md`
- `agents/fresh-agent-prompt.md`
- `handoff/README.md`

## Ownership / License

- owner: `mgit0771`
- repo role: operational SSOT for CCC dispatch
- Phase 1 license status: no standalone OSS license declared here; treat the
  contents as owner-controlled operational material unless the owner publishes a
  license later
