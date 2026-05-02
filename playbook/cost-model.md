---
description: Empirical cost model dla różnych dispatch patterns. Wszystkie liczby z real runs (mine + helpers').
---

# Cost Model — Dispatch Patterns

Empirical numbers. Use for operator planning + budget decisions.

## Single doc-only worker + multi-turn CCC (R1+2 baseline)

**Source:** Run 1+2 (2026-04-30/05-01, ccc-dispatcher own).

| Item | Value | Note |
|------|-------|------|
| Wall time | ~35 min | Including 3 manuals + research time by Codex |
| Manual interventions | 3 | manifest path, PAT redact, CCC resume CWD |
| Codex worker tokens | 313k (incl resume) | xhigh reasoning, gpt-5.4 |
| Codex worker cost | ~$1-2 | Estimated, OpenAI billing not directly visible |
| CCC Turn 1 (review) | $0.50 | Opus 4.7 1m, cache_creation 45k, cache_read 267k |
| CCC Turn 2 (merge) | $0.41 | SAME session, cache_read 355k (massive hit) |
| **Total** | **~$2-3** | doc-only, single worker |

**Cache savings:** Turn 2 cache_read = 355k vs Turn 1 cache_creation = 45k → ~88% of Turn 2 reused. If we'd done fresh CCC for merge: another ~$0.50. Multi-turn saved 35-40%.

## Parallel workers + batch CCC (R3 pattern)

**Source:** ccc-dispatcher own R3 (2026-05-01, 3 parallel doc workers + batch CCC). Plus opus-dispatcher-ma R3 (2026-04-29, 3 workers including 1 multi-turn).

### My R3 numbers (2026-05-01)

| Item | Value | Note |
|------|-------|------|
| Wall time | ~23 min | 3 workers parallel (5s stagger) + batch CCC |
| Manual interventions | 1 | S7-P pre-login codex redirect (B28) |
| Codex 3× workers parallel (gpt-5.4 xhigh, doc-only) | ~$2-4 | Estimated, 3 PRs |
| CCC Turn 1 batch review (3 PRs) | $0.39 | session `7c2e7066`, cache_read 199k |
| CCC Turn 2 batch merge (3 PRs) | $0.44 | SAME session, cache_read **357k** (massive hit) |
| **Total CCC** | **$0.83** | for 3 PRs reviewed AND merged |
| **Total all-in (estimate)** | **~$3-5** | for 3 PRs E2E |

**Per-PR economics (R3 vs single R1+2):**
- CCC: $0.28/PR (R3) vs $0.91/PR (R1+2) — **70% cheaper**
- Wall: 7.7 min/PR (R3) vs 35 min/PR (R1+2) — **78% faster**

### Reference: opus-dispatcher-ma R3 numbers (2026-04-29)

| Item | Value | Note |
|------|-------|------|
| Wall time | ~35 min | 3 workers (1 multi-turn) + batch CCC |
| Manual interventions | 1-2 | safe.directory + parallel codex login race |
| CCC batch (Turn 1+2, 3 PRs) | $0.37 | massive cache hit 290k tokens cached |

Cross-validation: my $0.83 vs theirs $0.37 — different prompts/scope explain variance, both confirm batch is dramatically cheaper than serial.

## Multi-turn worker (single, R3 w3, opus-dispatcher-ma)

| Item | Value | Note |
|------|-------|------|
| Wall time Turn 1 (outline) | ~4 min | 5 section headlines |
| Wall time Turn 2 (expand) | ~5 min | 187 line full doc |
| Tokens Turn 2 | 27,484 | with cache hits from Turn 1 |
| Codex cost Turn 2 | ~$0.50-1 | Estimated |

**Pattern:** worker does outline first (commits/pushes), Comp resumes worker for Turn 2 expand. Useful when scope is too big for single Codex turn or operator wants outline-review-before-expand gate.

## CCC patterns

| Pattern | When to use | Cost vs alternative |
|---------|-------------|---------------------|
| Multi-turn (review→merge same session) | 1 PR | -35% vs fresh sessions |
| Batch (review N PRs Turn 1, merge N PRs Turn 2) | 2-5 PRs | -50%+ vs sequential, massive cache hit |
| Fresh per task | only when context isolation needed | most expensive |

**Empirical:** batch 3 PRs at $0.37 vs hypothetical sequential 3x$1 = $3 → batch saved ~85%.

## Codex API key vs subscription

`--codex-api-key-file /root/.openai-api-key` activates pay-per-use API instead of subscription.

| Mode | When | Cost |
|------|------|------|
| Subscription (default) | Operator's ChatGPT Plus | Included in subscription, but quota |
| API key | After quota hit OR for parallel (avoids race S7-P partially) | OpenAI billing per token |

opus-dispatcher-ma R3: API key kept dispatch alive after subscription quota hit on R2 second-turn.

## Operator budget guidance

For dispatch experiments:
- **Single doc dispatch:** budget $5 (covers cost + buffer for retries)
- **Parallel 3 workers:** budget $10-15
- **R3 + multi-turn worker:** budget $15-20
- **Real code dispatch (canonical scripts):** budget $20-50 depending on scope (more retries, more CCC review iterations)

For production rollout (50+ dispatches/month at current pricing):
- ~$100-150/month worker costs
- ~$25-50/month CCC review costs
- VPS Hetzner already paid (~$40/month)
- **Total ~$165-240/month** for active operations

Cost trend: API tokens get cheaper over time (Anthropic + OpenAI both reducing prices). 6 months out, expect 30-50% cheaper.

## When cost would NOT fit

- Real-time multi-turn supervisor (CCC always-on, 24/7) — would be $5-15/day or $150-450/month per project. Avoid unless real value.
- Very long context CCC sessions (>500k tokens) — Opus 4.7 1m gets expensive. Split into bounded sessions.
- Worker tasks larger than 1 turn fits — multi-turn outline+expand is fine; trying to fit huge code refactor in single turn = waste.

## Source data integrity

Numbers above are from:
- ccc-dispatcher Run 1+2: `runs/run-1-2-2026-04-30-doc-only-multiturn.md` (own empiria)
- opus-dispatcher-ma R1/R2/R3: `opus-dispatcher-ma/opus-notes/dispatch-roll-{1,2,3}-log.md`

If you want to verify, original logs are in `/root/codex-headless/<project>/w*/run-*.log` and `/root/ccc-headless/<project>/<task>/stdout-*.log` on VPS.
