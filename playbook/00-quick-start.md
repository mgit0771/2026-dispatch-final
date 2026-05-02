---
description: Copy-paste exact commands for fresh-me to execute single doc-only worker dispatch + multi-turn CCC. Verified by Run 1+2 2026-04-30/05-01.
---

# Quick-Start Cheatsheet — Single Worker Doc-Only Dispatch

**Verified:** 2026-04-30/05-01 Run 1+2, ~35 min wall, 3 manuals, $2-3 total cost.

This is the reproducible sequence. Replace `{PROJECT}`, `{REPO_UPPER}`, `{TASK_DESC}` per dispatch. Other placeholders (`{PAT}`, paths) come from `01-CURRENT-STATE.md`.

## 0. Pre-flight (~30s)

```bash
# Check claudeuser fresh + codex key + overlay scripts
bash /tmp/vps.sh "python3 -c 'import json,time; d=json.load(open(\"/home/claudeuser/.claude/.credentials.json\")); h=int((d[\"claudeAiOauth\"][\"expiresAt\"]/1000-time.time())/3600); print(f\"claude: {h}h\")' && ls /root/.openai-api-key /root/2026-opus-dispatcher-ma/scripts/pre-dispatch-overlay-v2.sh && systemctl is-active claude-cmd-api.service"
```

Expected: `claude: ≥1h`, both files exist, `active`. Jeśli claude < 1h → operator `/login` claudeuser.

## 1. Create disposable repo (~30s)

```bash
PROJECT={PROJECT}                # e.g. ccc-roll-N-20260501
REPO_UPPER={REPO_UPPER}          # e.g. CCC-ROLL-N-20260501

curl -s -H "Authorization: token {PAT}" \
  -X POST -d "{\"name\":\"$REPO_UPPER\",\"private\":false,\"description\":\"ccc-dispatcher Run N test repo\",\"auto_init\":true}" \
  https://api.github.com/user/repos | python3 -c "import json,sys; d=json.load(sys.stdin); print('Created:' if 'full_name' in d else 'ERROR:', d.get('full_name', d.get('message')))"
```

## 2. Setup repo + user (~3 min, async)

```bash
bash /tmp/vps.sh "nohup bash -c 'set -e; export GITHUB_TOKEN={PAT} && bash /root/2026-loop/repo-comp-loop-env/scripts/setup-repo.sh --project $PROJECT --repo mgit0771/$REPO_UPPER --branch main && bash /root/2026-loop/repo-comp-loop-env/scripts/setup-user.sh --project $PROJECT' > /tmp/$PROJECT-setup.log 2>&1 & echo PID=\$!"

# Poll
bash /tmp/vps.sh "tail -10 /tmp/$PROJECT-setup.log"
```

Expected end: `[setup-user] User ready: ccuser-$PROJECT`. **Don't worry about HTTP 405** — overlay-v2 will fix B9 stale creds.

## 3. Apply overlay-v2 (~5s)

```bash
bash /tmp/vps.sh "bash /root/2026-opus-dispatcher-ma/scripts/pre-dispatch-overlay-v2.sh $PROJECT"
```

Expected: `done — $PROJECT ready for dispatch`, with `claude: +Xh`, `gh: github.com`, `codex config.toml perms: 644`.

## 4. Manifest (~2 min)

**KRYTYCZNE (B27):** redact PAT z manifest content jeśli go masz w Materials. Use placeholder `GITHUB_TOKEN env var (do not paste literal)`.

```bash
# Local: write manifest to /tmp/worker-{NAME}-manifest.md
# Then transfer to VPS:
B64=$(base64 -w0 /tmp/worker-w1-manifest.md)
bash /tmp/vps.sh "echo '$B64' | base64 -d > /tmp/worker-w1-manifest.md && grep -c ghp_ /tmp/worker-w1-manifest.md"
# Expected: 0 (no leaked PAT)

# Commit on worker branch:
bash /tmp/vps.sh "cd /tmp && rm -rf $PROJECT-staging && git clone https://mgit0771:{PAT}@github.com/mgit0771/$REPO_UPPER.git $PROJECT-staging && cd $PROJECT-staging && git checkout -b worker/$PROJECT-w1 && mkdir -p manifests && cp /tmp/worker-w1-manifest.md manifests/worker-w1.md && git -c user.email='mg@fractals-ai.com' -c user.name='mgit0771' add manifests/worker-w1.md && git -c user.email='mg@fractals-ai.com' -c user.name='mgit0771' commit -m 'manifest: dispatch worker w1' && git push -u origin worker/$PROJECT-w1 2>&1 | tail -3"
```

Jeśli push rejected z `secrets`: redact, reset branch (delete + recreate), retry.

## 5. Dispatch worker headless (~5-15 min Codex work)

**KRYTYCZNE (S7-Q):** add safe.directory. **B26:** absolute manifest path. **S7-N:** CWD = repo path.

```bash
bash /tmp/vps.sh "git config --global --add safe.directory /root/2026-loop/repo-$PROJECT && nohup bash -c 'cd /root/2026-loop/repo-$PROJECT && bash /root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/dispatch-worker.sh --project $PROJECT --worker-name w1 --manifest-file /tmp/worker-w1-manifest.md --user ccuser-$PROJECT --backend headless --codex-api-key-file /root/.openai-api-key' > /tmp/$PROJECT-dispatch.log 2>&1 & echo PID=\$!"

# Verify start
bash /tmp/vps.sh "sleep 3 && grep -E 'thread started|ERROR' /tmp/$PROJECT-dispatch.log | head -3"
# Expected: "thread started: <uuid>"
```

## 6. Wait worker DONE (poll loop)

```bash
# In Bash tool, run with run_in_background=true:
bash /tmp/vps.sh "until ! pgrep -f 'codex exec.*$PROJECT' >/dev/null 2>&1; do sleep 25; done; echo DONE"

# Then check:
bash /tmp/vps.sh "head -10 /root/codex-headless/$PROJECT/w1/final-*.txt 2>&1 | head -10"
# Expected: "Status: DONE", commit SHA, PR URL
```

## 7. CCC headless review (Turn 1, ~1 min)

```bash
# Write review prompt to /tmp/ccc-review-prompt.md, transfer:
B64=$(base64 -w0 /tmp/ccc-review-prompt.md)
bash /tmp/vps.sh "echo '$B64' | base64 -d > /tmp/ccc-review-prompt.md && nohup bash /root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/ccc-headless-task.sh --project $PROJECT --task pre-merge-review --prompt-file /tmp/ccc-review-prompt.md --user ccuser-$PROJECT --output-format json > /tmp/$PROJECT-review.log 2>&1 & echo PID=\$!"

# Wait + read verdict:
bash /tmp/vps.sh "until ! pgrep -f 'ccc-headless-task.*$PROJECT' >/dev/null 2>&1 && ! pgrep -f 'claude.*-p' >/dev/null 2>&1; do sleep 12; done; echo CCC_DONE"

# Extract session_id + verdict:
bash /tmp/vps.sh "find /root/ccc-headless/$PROJECT -name 'stdout-*.log' -exec cat {} \; | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"session_id:\", d[\"session_id\"]); print(\"---\"); print(d[\"result\"])'"
```

## 8. CCC headless merge (Turn 2 SAME session, ~30s)

**KRYTYCZNE (B25):** `cd /root/2026-loop/repo-$PROJECT` przed `claude --resume`.

```bash
SESSION_ID=<from previous step>

# Write merge prompt to /tmp/ccc-merge-prompt.md, transfer + execute:
B64=$(base64 -w0 /tmp/ccc-merge-prompt.md)
bash /tmp/vps.sh "echo '$B64' | base64 -d > /tmp/ccc-merge-prompt.md && nohup sudo -u ccuser-$PROJECT env HOME=/home/ccuser-$PROJECT bash -c 'cd /root/2026-loop/repo-$PROJECT && claude -p --resume $SESSION_ID --permission-mode bypassPermissions --output-format json --verbose < /tmp/ccc-merge-prompt.md' > /tmp/$PROJECT-merge.log 2>&1 & echo PID=\$!"

# Wait + read result:
bash /tmp/vps.sh "until ! pgrep -f 'claude.*resume.*$SESSION_ID' >/dev/null 2>&1; do sleep 10; done; tail -3 /tmp/$PROJECT-merge.log"
```

Expected: `MERGE_STATUS: SUCCESS`, `MERGED_SHA: <sha>`.

## 9. Teardown (~30s)

```bash
bash /tmp/vps.sh "bash /root/2026-loop/repo-comp-loop-env/scripts/teardown.sh --project $PROJECT --force 2>&1 | tail -10"
```

Expected: `Teardown complete for $PROJECT`. GitHub repo zachowany jako artifact.

## Manual interventions to expect

Per Run 1+2 empiria:
1. **Manifest path** if relative — fix by absolute `/tmp/`. (B26)
2. **PAT in manifest** if literal — fix by redact + reset+rebuild branch. (B27)
3. **CCC --resume CWD** — fix by `cd repo` before resume. (B25)

These are 3 manuals reasonable. If you hit MORE, something changed in environment.

## Cost expected

| Step | USD | Time |
|------|-----|------|
| Codex worker (gpt-5.4 xhigh, ~250 LOC doc) | ~$1-2 | 5-15 min |
| CCC Turn 1 review (Opus 4.7 1m) | ~$0.50 | ~1 min |
| CCC Turn 2 merge | ~$0.40 | ~30s |
| **Total** | **~$2-3** | **~35 min wall** |

Multi-turn vs fresh CCC twice: ~35% savings (cache reuse on Turn 2).

## When this is NOT what you want

- Real code change (not doc-only) → still works but pre-merge-check.sh + scope discipline matter more
- Parallel workers (3+) → use opus-dispatcher-ma/dispatch-master/04-PLAYBOOK-PARALLEL-WORKERS.md
- Multi-turn worker (outline → expand) → use 05-PLAYBOOK-MULTI-TURN-WORKER.md
- Pre-login codex required (S7-P) for parallel — overlay-v3 will cover
