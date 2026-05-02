# 2026-dispatch-final

CCC Dispatch Pipeline SSOT, Phase 3 of 4.

This repository centralizes the current dispatch stack in one place:

- orchestrator scripts
- copied shell tests
- operator playbook
- fresh-agent bootstrap prompt
- handoff pointers
- reusable templates
- `bootstrap.sh` for a new dispatcher account

## Phase 3 Status

As of 2026-05-02 this repo is the canonical home for the artifacts and the
active dispatch chain now derives its runtime defaults from `${DISPATCH_HOME}`.

- `bootstrap.sh` prepares a per-dispatcher user, home, repo checkout, secret
  files, registries, and log directories.
- `scripts/dispatch-pre.sh` plus the hardened F2/F3/F4 variants require
  `DISPATCH_HOME` and derive their default paths from the bootstrap layout.
- `scripts/ccc-headless-task.sh` now lives in-repo and uses the same
  dispatcher-scoped runtime layout as the hardened orchestrators.
- Anthropic access in the active chain is now stateless: one dispatcher-owned
  `${DISPATCH_HOME}/.config/anthropic-api-key` is validated at runtime and
  injected via `ANTHROPIC_API_KEY`, with no per-user OAuth refresh/TTL path.
- Historical original scripts remain in `scripts/` as reference artifacts and
  are intentionally untouched.

Practical meaning:

- one dispatcher account = one `${DISPATCH_HOME}`
- multi-instance setups can isolate repos, headless artifacts, logs, and
  registries without shared host-global defaults in the active chain

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
export DISPATCH_HOME=/home/dispatcher-alpha
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
- `tests/` -> shell tests for the active dispatch chain
- `playbook/` -> quick start, economics, decision rules, blocker summary
- `templates/` -> worker manifest and CCC prompt templates
- `agents/` -> fresh-agent cold-start prompt
- `handoff/` -> key ownership docs plus pointer to the full long-form package
- `docs/architecture.md` -> actors, flow, headless-first, isolation target

## Workflow

Nominal Phase 2 path:

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
