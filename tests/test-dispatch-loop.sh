#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/dispatch-loop.sh"

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
  local outfile="$1"
  shift
  set +e
  "$@" >"$outfile" 2>&1
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

  mkdir -p "${dir}/scripts" "${dir}/loop-root"
  cat >"${dir}/manifest.md" <<'EOF'
# Worker Manifest
EOF
  cat >"${dir}/review.md" <<'EOF'
# Review Prompt
EOF
  make_creds "${dir}/claude-credentials.json"

  cat >"${dir}/scripts/dispatch-pre.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

project=""
worker="w1"
manifest_file=""
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) project="$2"; shift 2 ;;
    --manifest-file) manifest_file="$2"; shift 2 ;;
    --worker-name) worker="$2"; shift 2 ;;
    --target-repo) shift 2 ;;
    --create-repo) shift ;;
    --dry-run) dry_run=1; shift ;;
    *) shift ;;
  esac
done

if [ "${MOCK_F1_MODE:-success}" = "fail" ]; then
  printf '[dispatch-pre] ERROR: mock failure\n' >&2
  exit 1
fi

install -m 600 "$manifest_file" "/tmp/${project}-${worker}-manifest.md"
printf '[dispatch-pre] Phase 0 (pre-flight): %s\n' "$([ "$dry_run" -eq 1 ] && printf 'DRY-RUN' || printf 'OK')"
printf '[dispatch-pre] Phase 7 (verify): thread_id=%s, codex live\n' "${MOCK_F1_THREAD_ID:-thread-mock-123}"
EOF

  cat >"${dir}/scripts/dispatch-review-merge.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

project=""
worker="w1"
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) project="$2"; shift 2 ;;
    --worker-name) worker="$2"; shift 2 ;;
    --target-repo|--review-prompt-file|--mode|--max-wait-sec) shift 2 ;;
    --teardown) shift ;;
    --dry-run) dry_run=1; shift ;;
    *) shift ;;
  esac
done

case "${MOCK_F2_MODE:-success}" in
  success)
    printf '[dispatch-review-merge] Phase 7 (wait worker DONE): %s\n' "$([ "$dry_run" -eq 1 ] && printf 'DRY-RUN' || printf 'worker complete')"
    printf 'review_verdict=PASS\n'
    printf 'review_session_id=review-session-1\n'
    printf 'review_cost_usd=1.5\n'
    printf 'merge_status=success\n'
    printf 'merge_session_id=review-session-1\n'
    printf 'merge_cost_usd=0.5\n'
    printf 'merged_sha=feedface\n'
    ;;
  b30)
    cat >"/tmp/${project}-merge.log" <<JSON
[
  {"type":"progress","message":"verbose"},
  {"type":"result","session_id":"merge-session-1","total_cost_usd":0.75,"result":"MERGE_STATUS: success\nMERGED_SHA: cafe1234"}
]
JSON
    printf 'review_verdict=PASS\n'
    printf 'review_session_id=review-session-1\n'
    printf 'review_cost_usd=1.25\n'
    printf '[dispatch-review-merge] ERROR: Could not find JSON output in /tmp/%s-merge.log.\n' "$project" >&2
    exit 6
    ;;
  worker_crash)
    mkdir -p "${DISPATCH_LOOP_LOOP_ROOT}/repo-${project}/.letta/worktrees/worker-${project}-${worker}"
    printf 'partial work\n' >"${DISPATCH_LOOP_LOOP_ROOT}/repo-${project}/.letta/worktrees/worker-${project}-${worker}/notes.txt"
    sleep 1
    printf '[dispatch-review-merge] ERROR: Worker process is gone but no non-empty final output was found under /root/codex-headless/%s/%s.\n' "$project" "$worker" >&2
    exit 4
    ;;
  *)
    printf '[dispatch-review-merge] ERROR: unsupported MOCK_F2_MODE=%s\n' "${MOCK_F2_MODE:-unknown}" >&2
    exit 99
    ;;
esac
EOF

  chmod +x "${dir}/scripts/dispatch-pre.sh" "${dir}/scripts/dispatch-review-merge.sh"
}

base_args() {
  local dir="$1" project="$2"
  printf '%s\0' \
    --project "$project" \
    --manifest-file "${dir}/manifest.md" \
    --target-repo owner/repo \
    --review-prompt-file "${dir}/review.md" \
    --scripts-dir "${dir}/scripts"
}

run_case_dry_run() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  mapfile -d '' -t args < <(base_args "$dir" dryrunproj)
  run_capture "$out" env \
    DISPATCH_LOOP_CLAUDE_CREDENTIALS_FILE="${dir}/claude-credentials.json" \
    DISPATCH_LOOP_LOOP_ROOT="${dir}/loop-root" \
    MOCK_F1_MODE=success \
    MOCK_F2_MODE=success \
    bash "$SCRIPT" "${args[@]}" --dry-run

  assert_status "$RUN_STATUS" 0 "dry-run"
  assert_contains "$out" "DRY-RUN" "dry-run"
  assert_contains "$out" '"status":"merged"' "dry-run"
}

run_case_missing_project() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  run_capture "$out" env \
    DISPATCH_LOOP_CLAUDE_CREDENTIALS_FILE="${dir}/claude-credentials.json" \
    bash "$SCRIPT" \
    --manifest-file "${dir}/manifest.md" \
    --target-repo owner/repo \
    --review-prompt-file "${dir}/review.md" \
    --scripts-dir "${dir}/scripts"

  assert_status "$RUN_STATUS" 1 "missing-project"
  assert_contains "$out" "--project is required." "missing-project"
}

run_case_missing_manifest() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  run_capture "$out" env \
    DISPATCH_LOOP_CLAUDE_CREDENTIALS_FILE="${dir}/claude-credentials.json" \
    bash "$SCRIPT" \
    --project missingmanifest \
    --target-repo owner/repo \
    --review-prompt-file "${dir}/review.md" \
    --scripts-dir "${dir}/scripts"

  assert_status "$RUN_STATUS" 1 "missing-manifest"
  assert_contains "$out" "--manifest-file is required." "missing-manifest"
}

run_case_b29() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  mapfile -d '' -t args < <(base_args "$dir" abcdefghijklmnopqrstuvwxyz)
  run_capture "$out" env \
    DISPATCH_LOOP_CLAUDE_CREDENTIALS_FILE="${dir}/claude-credentials.json" \
    bash "$SCRIPT" "${args[@]}"

  assert_status "$RUN_STATUS" 1 "b29"
  assert_contains "$out" "B29" "b29"
}

run_case_f1_failure() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  mapfile -d '' -t args < <(base_args "$dir" f1failproj)
  run_capture "$out" env \
    DISPATCH_LOOP_CLAUDE_CREDENTIALS_FILE="${dir}/claude-credentials.json" \
    DISPATCH_LOOP_LOOP_ROOT="${dir}/loop-root" \
    MOCK_F1_MODE=fail \
    bash "$SCRIPT" "${args[@]}"

  assert_status "$RUN_STATUS" 1 "f1-fail"
  assert_contains "$out" "F1 failed with status 1" "f1-fail"
}

run_case_b30_recovery() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  mapfile -d '' -t args < <(base_args "$dir" b30recoverproj)
  run_capture "$out" env \
    DISPATCH_LOOP_CLAUDE_CREDENTIALS_FILE="${dir}/claude-credentials.json" \
    DISPATCH_LOOP_LOOP_ROOT="${dir}/loop-root" \
    MOCK_F1_MODE=success \
    MOCK_F2_MODE=b30 \
    bash "$SCRIPT" "${args[@]}"

  assert_status "$RUN_STATUS" 0 "b30-recovery"
  assert_contains "$out" "f2_status=recovered_b30 merged_sha=cafe1234" "b30-recovery"
  assert_contains "$out" '"merged_sha":"cafe1234"' "b30-recovery"
}

run_case_worker_crash() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  mapfile -d '' -t args < <(base_args "$dir" crashrecoverproj)
  run_capture "$out" env \
    DISPATCH_LOOP_CLAUDE_CREDENTIALS_FILE="${dir}/claude-credentials.json" \
    DISPATCH_LOOP_LOOP_ROOT="${dir}/loop-root" \
    MOCK_F1_MODE=success \
    MOCK_F2_MODE=worker_crash \
    bash "$SCRIPT" "${args[@]}"

  assert_status "$RUN_STATUS" 7 "worker-crash"
  assert_contains "$out" "WORKER_CRASH_DETECTED" "worker-crash"
  assert_contains "$out" "crash_file=" "worker-crash"
  assert_contains "$out" '"status":"crash"' "worker-crash"
}

main() {
  run_case_dry_run
  run_case_missing_project
  run_case_missing_manifest
  run_case_b29
  run_case_f1_failure
  run_case_b30_recovery
  run_case_worker_crash
  printf 'PASS: test-dispatch-loop.sh\n'
}

main "$@"
