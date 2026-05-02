#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/dispatch-batch.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_status() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" -eq "$expected" ] || fail "${label}: expected exit ${expected}, got ${actual}"
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  grep -Fq -- "$needle" "$file" || {
    printf '--- output (%s) ---\n' "$label" >&2
    cat "$file" >&2
    printf '--------------------\n' >&2
    fail "${label}: expected output to contain: ${needle}"
  }
}

run_capture() {
  local stdout_file="$1" stderr_file="$2"
  shift 2
  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  RUN_STATUS=$?
  set -e
}

make_creds() {
  local path="$1"
  python3 - "$path" <<'PY'
import json
import sys
import time

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"claudeAiOauth": {"expiresAt": int((time.time() + 7200) * 1000)}}, handle)
PY
}

setup_fixture() {
  local dir="$1"

  mkdir -p "${dir}/scripts" "${dir}/manifests" "${dir}/bin" "${dir}/loop-root" "${dir}/headless" "${dir}/home"
  printf '# review template\n' >"${dir}/review.md"
  printf '# worker 1\n' >"${dir}/manifests/worker-w1.md"
  printf '# worker 2\n' >"${dir}/manifests/worker-w2.md"
  printf '# worker 3\n' >"${dir}/manifests/worker-w3.md"
  make_creds "${dir}/claude-credentials.json"

  cat >"${dir}/scripts/dispatch-pre.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

project=""; worker=""; dry_run=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) project="$2"; shift 2 ;;
    --worker-name) worker="$2"; shift 2 ;;
    --manifest-file|--target-repo) shift 2 ;;
    --create-repo) shift ;;
    --dry-run) dry_run=1; shift ;;
    *) shift ;;
  esac
done

mkdir -p "${DISPATCH_BATCH_LOOP_ROOT}/repo-${project}" "${DISPATCH_BATCH_CODEX_HEADLESS_ROOT}/${project}/${worker}"
printf 'done\n' >"${DISPATCH_BATCH_CODEX_HEADLESS_ROOT}/${project}/${worker}/final-20260501.txt"
printf '[dispatch-pre] Phase 7 (verify): thread_id=thread-%s, codex live\n' "$worker"
if [ "$dry_run" -eq 1 ]; then
  printf '[dispatch-pre] DRY-RUN\n'
fi
EOF

  cat >"${dir}/scripts/dispatch-review-merge.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"${dir}/scripts/dispatch-loop.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"${dir}/ccc-headless-task.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"session_id":"review-session-1","total_cost_usd":0.39,"result":"PR #1: PASS\nPR #2: WARN\nPR #3: FAIL\nOVERALL_RECOMMENDATION: merge-pass-only"}'
EOF

  cat >"${dir}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  auth)
    exit 0
    ;;
  repo)
    shift
    [ "${1:-}" = "view" ] || exit 1
    printf 'https://github.com/%s\n' "${2:-owner/repo}"
    ;;
  api)
    shift
    if [ "${1:-}" = "user" ]; then
      printf 'tester\n'
    else
      printf 'https://github.com/tester/created\n'
    fi
    ;;
  pr)
    shift
    [ "${1:-}" = "list" ] || exit 1
    repo=""
    head=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --head) head="$2"; shift 2 ;;
        --state|--json) shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "$head" =~ w([0-9]+)$ ]]; then
      num="${BASH_REMATCH[1]}"
    else
      num="1"
    fi
    printf '[{"url":"https://github.com/%s/pull/%s","number":%s,"headRefOid":"deadbee%s"}]\n' "$repo" "$num" "$num" "$num"
    ;;
  *)
    exit 0
    ;;
esac
EOF

  cat >"${dir}/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

  cat >"${dir}/bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '0\n'
  exit 0
fi
if [[ "${1:-}" == ccuser-* ]]; then
  exit 0
fi
exec /usr/bin/id "$@"
EOF

  cat >"${dir}/bin/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "passwd" ] && [[ "${2:-}" == ccuser-* ]]; then
  mkdir -p "${DISPATCH_BATCH_TEST_HOME_ROOT}/${2}"
  printf '%s:x:1001:1001::%s/%s:/bin/bash\n' "$2" "${DISPATCH_BATCH_TEST_HOME_ROOT}" "$2"
  exit 0
fi
exec /usr/bin/getent "$@"
EOF

  cat >"${dir}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=("$@")
if [ "${args[0]:-}" = "-u" ]; then
  args=("${args[@]:2}")
fi
if [ "${args[0]:-}" = "env" ]; then
  env_args=()
  i=1
  while [ "$i" -lt "${#args[@]}" ] && [[ "${args[$i]}" == *=* ]]; do
    env_args+=("${args[$i]}")
    i=$((i + 1))
  done
  cmd=("${args[@]:$i}")
  if [ "${cmd[0]:-}" = "bash" ] && [ "${cmd[1]:-}" = "-lc" ]; then
    cmd=("bash" "-c" "${cmd[@]:2}")
  fi
  exec env "${env_args[@]}" "${cmd[@]}"
fi
exec "${args[@]}"
EOF

  cat >"${dir}/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[{"session_id":"review-session-1","total_cost_usd":0.44,"result":"PR #1 MERGE_STATUS: merged\nPR #1 MERGED_SHA: cafe1234\nPR #2 MERGE_STATUS: skipped_non_pass\nPR #2 MERGED_SHA: none\nPR #3 MERGE_STATUS: skipped_non_pass\nPR #3 MERGED_SHA: none\nBATCH_STATUS: partial"}]'
EOF

  chmod +x \
    "${dir}/scripts/dispatch-pre.sh" \
    "${dir}/scripts/dispatch-review-merge.sh" \
    "${dir}/scripts/dispatch-loop.sh" \
    "${dir}/ccc-headless-task.sh" \
    "${dir}/bin/gh" \
    "${dir}/bin/pgrep" \
    "${dir}/bin/id" \
    "${dir}/bin/getent" \
    "${dir}/bin/sudo" \
    "${dir}/bin/claude"

  mkdir -p "${dir}/home/ccuser-batchok-w1/.npm-global/bin"
  ln -sf "${dir}/bin/claude" "${dir}/home/ccuser-batchok-w1/.npm-global/bin/claude"
  ln -sf "${dir}/bin/gh" "${dir}/home/ccuser-batchok-w1/.npm-global/bin/gh"
}

base_env() {
  local dir="$1"
  printf '%s\0' \
    "PATH=${dir}/bin:${PATH}" \
    "DISPATCH_BATCH_CLAUDE_CREDENTIALS_FILE=${dir}/claude-credentials.json" \
    "DISPATCH_BATCH_CCC_TASK_SCRIPT=${dir}/ccc-headless-task.sh" \
    "DISPATCH_BATCH_LOOP_ROOT=${dir}/loop-root" \
    "DISPATCH_BATCH_CODEX_HEADLESS_ROOT=${dir}/headless" \
    "DISPATCH_BATCH_STAGGER_SEC=0" \
    "DISPATCH_BATCH_TEST_HOME_ROOT=${dir}/home" \
    "GITHUB_TOKEN=dummy-token"
}

run_case_dry_run() {
  local dir stdout_file stderr_file
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  setup_fixture "$dir"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --project-prefix batchok \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --scripts-dir "${dir}/scripts" \
    --dry-run

  assert_status "$RUN_STATUS" 0 "dry-run"
  jq -e '.batch_prefix == "batchok" and .n_workers == 3 and (.results_per_worker | length) == 3' "$stdout_file" >/dev/null \
    || fail "dry-run: invalid JSON summary"
}

run_case_missing_project_prefix() {
  local dir stdout_file stderr_file
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  setup_fixture "$dir"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --scripts-dir "${dir}/scripts" \
    --dry-run

  assert_status "$RUN_STATUS" 1 "missing-project-prefix"
  assert_contains "$stderr_file" "--project-prefix is required." "missing-project-prefix"
}

run_case_missing_manifests_dir() {
  local dir stdout_file stderr_file
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  setup_fixture "$dir"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --project-prefix batchok \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --scripts-dir "${dir}/scripts" \
    --dry-run

  assert_status "$RUN_STATUS" 1 "missing-manifests-dir"
  assert_contains "$stderr_file" "--manifests-dir is required." "missing-manifests-dir"
}

run_case_empty_manifests_dir() {
  local dir stdout_file stderr_file
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  setup_fixture "$dir"
  rm -f "${dir}/manifests/"*.md

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --project-prefix batchok \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --scripts-dir "${dir}/scripts" \
    --dry-run

  assert_status "$RUN_STATUS" 1 "empty-manifests-dir"
  assert_contains "$stderr_file" "No worker manifests found" "empty-manifests-dir"
}

run_case_b29() {
  local dir stdout_file stderr_file
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  setup_fixture "$dir"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --project-prefix abcdefghijklmnopqrstuvw \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --scripts-dir "${dir}/scripts" \
    --dry-run

  assert_status "$RUN_STATUS" 1 "b29"
  assert_contains "$stderr_file" "B29" "b29"
}

run_case_verdict_parsing() {
  local dir stdout_file stderr_file
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  setup_fixture "$dir"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --project-prefix batchok \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --scripts-dir "${dir}/scripts" \
    --mode auto

  assert_status "$RUN_STATUS" 12 "verdict-parsing"
  jq -e '
    .status == "partial" and
    (.results_per_worker[] | select(.worker == "w1") | .verdict == "PASS" and .status == "merged" and .merged_sha == "cafe1234") and
    (.results_per_worker[] | select(.worker == "w2") | .verdict == "WARN" and .status == "skipped") and
    (.results_per_worker[] | select(.worker == "w3") | .verdict == "FAIL" and .status == "skipped")
  ' "$stdout_file" >/dev/null || fail "verdict-parsing: summary mismatch"
}

run_case_dry_run
run_case_missing_project_prefix
run_case_missing_manifests_dir
run_case_empty_manifests_dir
run_case_b29
run_case_verdict_parsing

printf 'PASS: test-dispatch-batch.sh\n'
