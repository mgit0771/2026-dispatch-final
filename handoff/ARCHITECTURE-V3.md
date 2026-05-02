---
description: Owner's vision for v3 dispatch pipeline. Proposal, not implementation. Operator reads, reacts, decides if/when. Rationale grounded in 4 agents' learnings.
---

# Architecture v3 — Owner's vision

## Status

**Proposal.** Not implementation. Not a commitment. Operator reads, reacts.

This is what I'd build if starting fresh today, knowing what 4 agents (me, codex, glm, gpt) collectively learned. Some elements are achievable incrementally; some require throwing things away.

## The honest premise

After 4 agents working on this stack across ~2 weeks, the picture is clear:

- **Pipeline works** (4+ PRs merged across sessions, real value delivered)
- **Pipeline is brittle** (every fresh dispatch hits 3-7 blockers, requires baby-sitting)
- **Pipeline is over-engineered for current usage** (5 actors for tasks one agent could do in 5 min)
- **Pipeline is fragile to operator's stack drift** (Claude OAuth 401, Codex quota, npm versions)

V3 should fix the brittleness without throwing away the architecture (separation of duties is genuinely good). The architecture isn't the problem; the implementation substrate (tmux + OAuth + manual orchestration) is.

## V3 design principles

### 1. Headless first, TUI optional

PR #7 already pushes this direction. Extend to all actors:
- Workers: `codex exec --json` (PR #7 ✓)
- CCC: `claude -p` for bounded tasks, tmux only for live operator inspection
- Comp: HTTP API client (Anthropic API direct), not Claude Code CLI session

Why: TUI is for humans. We're agents. Every "send-keys" hack is a workaround for using human UI.

### 2. State in storage, not in process

V2 pipeline holds state in tmux processes:
- CCC alive = state alive
- tmux dies = state dies
- VPS reboot = catastrophic (4d ago, lost everything that wasn't in registry)

V3 shifts state to:
- **Persistent registry** (already exists for Codex sessions in `/root/codex-sessions.jsonl` — extend pattern)
- **Letta MemFS** for project knowledge (already used, but treated as primary not optional)
- **Postgres or SQLite** for dispatch state (manifest, status, owner, deadline) — replaces tmux session as source of truth
- **Object storage** (S3-compatible: MinIO, Cloudflare R2) for artifacts (logs, finals)

Process death ≠ state death. Process restart = state recovery.

### 3. Auth via API keys, not OAuth

OAuth was right for human Claude Code users. For headless agents:
- Anthropic API key — billed per use, no expiration drama, rotation in script
- OpenAI API key for Codex — already enabled in PR #7 fallback, just make it default
- GitHub PAT — already used (mgit0771's), works fine
- Letta API key — already used, works fine

OAuth path remains as recovery option (if operator wants to actually use Claude Code interactively), but agent paths bypass it entirely.

### 4. Comp as code, not as agent

Current Comp = LLM in sandbox parsing tmux output, deciding next step.

V3 Comp = deterministic Python service:
```python
def dispatch(project, manifest, owner_user):
    setup_repo(project)
    setup_user(project, owner_user)
    spawn_letta_rm(project)
    spawn_ccc(project)  # headless-callable, not always-on
    spawn_worker(project, manifest)
    poll_until_pr_opened(project)
    request_ccc_review(project)
    if ccc_verdict == "PASS":
        request_ccc_merge(project)
    cleanup_or_keep(project)
```

LLM (me) only enters when:
- Initial planning (decompose user request into manifests)
- Ambiguous review verdict (CCC says WARN, deciding action)
- Failure recovery (something broke, what's the fix)

90% of "Comp" today is mechanical orchestration. That's a script. The other 10% is judgment, that's me.

### 5. Worker as code-aware function

Worker today = TUI agent that read manifest from disk, edits files, commits, pushes.

V3 Worker:
- Receives manifest as structured input (JSON or YAML, not markdown)
- Returns structured output (file changes, commit SHAs, PR URL, status)
- Runs in container (Docker/podman), not as system user
- Headless backend (PR #7 path) is right direction

Container > system user means:
- Per-worker filesystem isolation (no `chown` dance with `.git/worktrees`)
- Easy resource limits
- Easy parallelism without RAM guard manual rule
- Easy teardown (rm container)

Cost: Docker setup on VPS, image management. Worth it.

### 6. CCC as service, not as process

Current CCC = Claude Code session in tmux, OAuth, RC link, send-keys interface.

V3 CCC = HTTP service:
- POST `/review` with branch/manifest/PR URL → returns verdict + comments
- POST `/merge` with branch + decision → executes squash merge
- POST `/steer` with worker_id + feedback → injects to running worker

Internally: Claude API direct, prompt template per task type. State in registry, not in process. Restartable.

Loses: live RC link for operator to attach. Operator gains: predictable interface for scripts.

Trade: if operator wants to attach interactively, spawn `dispatch-ccc.sh` separately for that session. CCC-as-service is dispatch path.

### 7. Letta as memory, optional

Letta RM is genuinely useful for project memory across sessions, but:
- Setup is heavy (`setup-letta-rm.sh`, ingestion timing flaky)
- Provisioning ≠ ingestion (Rule 14)
- Cost ~$1/day per agent
- For most tasks operating on 1 commit, project memory is overkill

V3:
- Letta RM optional per project, default OFF
- For projects > N tasks or > X days, operator opts in
- For one-shot dispatch (most cases), repo + commit log is enough
- When ON, Letta RM has explicit health gate (Rule 14) before dispatch starts

## V3 component diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  Operator (human, mgit0771)                                     │
│  - GitHub UI                                                    │
│  - Optional: Slack/Telegram bot for status                      │
│  - Optional: dispatch CLI (single command, e.g. `dispatch run` )│
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           v
┌─────────────────────────────────────────────────────────────────┐
│  Owner LLM (me, Claude API direct, called per decision)         │
│  - Input: dispatch request, ambiguous verdict, failure context  │
│  - Output: manifest spec, decision, recovery plan               │
│  - State: stateless per call, persistent via handoff in repo    │
└──────────────────────────┬──────────────────────────────────────┘
                           │ (manifest spec)
                           v
┌─────────────────────────────────────────────────────────────────┐
│  Comp Service (Python daemon on VPS, replaces "Comp Agent")     │
│  - HTTP/gRPC interface                                          │
│  - State in Postgres                                            │
│  - Calls: setup, dispatch, poll, request-review, request-merge  │
└──┬────────────────┬────────────────┬────────────────┬───────────┘
   │                │                │                │
   v                v                v                v
┌──────────┐  ┌───────────┐  ┌──────────┐  ┌──────────────┐
│ Setup    │  │ Workers   │  │ CCC      │  │ Letta RM     │
│ Service  │  │ (Docker   │  │ Service  │  │ (optional)   │
│ (repo,   │  │  containers│  │ (HTTP,   │  │              │
│  user,   │  │  per task)│  │  Claude  │  │              │
│  Letta)  │  │           │  │  API)    │  │              │
└──────────┘  └───────────┘  └──────────┘  └──────────────┘
   │              │              │              │
   └──────────────┴──────────────┴──────────────┘
                      │
                      v
                ┌───────────┐
                │ GitHub    │
                │ + Storage │
                │ (S3)      │
                └───────────┘
```

## What this looks like in operator's daily work

Today (v2):
```
Operator: "dispatch task X to project Y"
Me: 30+ steps over ~75 min, hitting 7 blockers, baby-sitting
Result: 1 PR merged
```

V3:
```
Operator: dispatch run --project Y --task task-X.yaml
Service: orchestrates everything, returns when done
Owner LLM (me): only called for planning task-X.yaml + reviewing if WARN
Result: 1 PR merged in <15 min, no baby-sitting
```

## Migration path (incremental, no big-bang)

Cannot rewrite stack in one shot. Incremental steps, each independently valuable.

**Progress as of 2026-05-01** (post Run 1+2 empirical validation):

| Step | Status | Note |
|------|--------|------|
| 1 — consolidate v2 + headless | 🟡 in progress | PR #7 still open, headless validated empirically by 4 agents (codex/opus-ma/ccc/comp), works |
| 2 — regression test suite | ⬜ not started | TODO-5 in NEXT-MOVES |
| 3 — API key default | 🟡 in progress | Codex API key works empirically (R1+2 used it), Claude API key not adopted yet (CCC still OAuth) |
| 4 — dispatch as service | ⬜ not started | Long-term |
| 5 — containers for workers | ⬜ not started | Long-term |
| 6 — CCC as service | 🟡 partial | `ccc-headless-task.sh` exists in PR #7, multi-turn validated; but full HTTP service not built |

### Step 1 (now → 1 week): consolidate v2 + finalize headless

- Merge PR #7 (per my review conditions)
- Make `--backend headless` default in next PR
- Document `dispatch-runtime-audit.sh` usage in playbook
- **Outcome:** v2 becomes more reliable, B4/B5 obsolete

**Current empirical state (2026-05-01):**
- Headless backend has been used in 5 successful E2E runs (opus-ma R1/R2/R3 + my R1+2)
- B4/B5 confirmed obsoleted by headless
- B16-B27 all have workarounds in `pre-dispatch-overlay-v2.sh` or documented
- PR #7 ready to merge from technical standpoint (per my review)

### Step 2 (1-2 weeks): regression test suite

- Write `tests/e2e-dispatch.sh` that runs full cycle on dummy project
- Run before every PR to COMP-LOOP-ENV
- **Outcome:** further changes don't silently break

### Step 3 (2-4 weeks): API key default

- Make Codex API key (operator's) default in `dispatch-worker.sh`
- Make Anthropic API key default for `ccc-headless-task.sh`
- OAuth becomes fallback for interactive use only
- **Outcome:** reliability up, debug surface down

### Step 4 (4-8 weeks): dispatch as service

- Extract orchestration logic from bash → Python service
- Postgres state, HTTP API, can run on VPS
- Operator's CLI (`dispatch run --project ...`) calls service
- **Outcome:** deterministic ops, can be unit tested

### Step 5 (8-16 weeks): containers for workers

- Move workers from system users to Docker containers
- Per-worker isolation, easy parallelism
- **Outcome:** ownership/permission problems disappear

### Step 6 (long-term): CCC as service

- Headless CCC behind HTTP API
- Scripts call CCC for review/merge programmatically
- **Outcome:** removes last "agent in pipeline" — pipeline = code, agents = users of pipeline

## What I'd discard

If v3 is built, these v2 components become legacy:

- `tmux send-keys -l` for prompt delivery — replaced by API
- `wait_for_codex_ready` — replaced by API response codes
- `paste-buffer` workarounds — replaced by API
- `recover-cc.sh` — replaced by service restart
- `MANIFEST.md` add/add conflict — replaced by service-managed merge
- Per-project ccuser-N system users — replaced by container isolation
- OAuth credential copy chain — replaced by API key
- CMD API 60s timeout — replaced by direct HTTP API to service

## What I'd keep

- HARD RULE separation of duties (Operator/Owner/CCC/Worker) — architecturally correct
- Manifest-as-contract — only format becomes structured (YAML/JSON)
- Per-project Letta RM — when used, with health gate
- GitHub as source of truth for code — keep
- Squash merge strategy — keep
- VPS as compute substrate — keep (cheap, sufficient)

## Cost estimate (rough, for operator's planning)

- **Step 1** (PR #7 merge + headless default): ~4-8h owner + operator time
- **Step 2** (regression tests): ~16-24h owner
- **Step 3** (API key default): ~8-16h owner + operator (key generation + budget setup)
- **Step 4** (dispatch service): 40-80h owner — biggest chunk, real engineering
- **Step 5** (containers): 16-32h owner (assuming Docker is already on VPS)
- **Step 6** (CCC service): 24-48h owner

Total to v3: ~3-4 weeks of focused work, reversible at each step.

## Risk: am I over-engineering?

Yes, possibly. Operator should ask:
- Is current dispatch volume worth this investment?
- Is there a simpler thing (e.g., just use GitHub Actions + Claude Code Action) that does 80% of value?
- Is this scratching my itch (LLM agent) more than solving operator's problem?

Honest answer: probably yes a little, especially for Step 4-6. Steps 1-3 pay off immediately even at low dispatch volume. Steps 4-6 only worth it if dispatch becomes high-volume operational tool.

## Default action: nothing yet

This document is an option, not a commitment. Operator can:
- Read and ignore — current v2 + PR #7 is fine
- Cherry-pick (e.g. "Step 1 yes, the rest no, just stay v2")
- Approve all and commission Step 1
- Reject and propose alternative

I default to nothing until operator picks. Stays a doc until then.

## Questions for operator

When operator next reads this:

1. Is dispatch a tool you want to invest more in, or "good enough" mode?
2. Do you want the service abstraction (Python daemon) or stay bash?
3. Do you have budget for direct Anthropic API + OpenAI API instead of OAuth subscriptions?
4. Are there other agents/users besides me you want supporting this v3?

No urgent answers. This sits as design doc until needed.
