#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/dispatch-batch-hardened.sh"

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
    printf -- '--- output (%s) ---\n' "$label" >&2
    cat "$file" >&2
    printf -- '--------------------\n' >&2
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

slug_from_dir() {
  local dir="$1" prefix="$2" suffix=""
  suffix="$(basename "$dir" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  suffix="${suffix:0:10}"
  printf '%s%s\n' "$prefix" "$suffix"
}

write_api_key() {
  local path="$1"
  printf 'mock-anthropic-test-key-12345\n' >"$path"
  chmod 600 "$path"
}

setup_worker_home() {
  local dir="$1" project="$2"
  mkdir -p "${dir}/home/ccuser-${project}/.npm-global/bin"
  ln -sf "${dir}/bin/claude" "${dir}/home/ccuser-${project}/.npm-global/bin/claude"
  ln -sf "${dir}/bin/gh" "${dir}/home/ccuser-${project}/.npm-global/bin/gh"
}

setup_fixture() {
  local dir="$1" prefix="$2" dispatch_home="" scripts_dir=""
  dispatch_home="${dir}/dispatcher-test"
  scripts_dir="${dispatch_home}/dispatch/scripts"

  mkdir -p \
    "${scripts_dir}" \
    "${dispatch_home}/repos" \
    "${dispatch_home}/.codex-headless" \
    "${dispatch_home}/.ccc-headless" \
    "${dispatch_home}/logs" \
    "${dispatch_home}/registries" \
    "${dispatch_home}/.config" \
    "${dir}/manifests" \
    "${dir}/bin" \
    "${dir}/home"
  printf '# review template\n' >"${dir}/review.md"
  printf '# worker 1\n' >"${dir}/manifests/worker-w1.md"
  printf '# worker 2\n' >"${dir}/manifests/worker-w2.md"
  printf '# worker 3\n' >"${dir}/manifests/worker-w3.md"
  write_api_key "${dispatch_home}/.config/anthropic-api-key"

  cat >"${scripts_dir}/dispatch-pre.sh" <<'EOF'
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

mkdir -p "${DISPATCH_HOME}/repos/${project}" "${DISPATCH_HOME}/.codex-headless/${project}/${worker}"
printf 'done\n' >"${DISPATCH_HOME}/.codex-headless/${project}/${worker}/final-20260501.txt"
printf '[dispatch-pre] Phase 7 (verify): thread_id=thread-%s, codex live\n' "$worker"
if [ "$dry_run" -eq 1 ]; then
  printf '[dispatch-pre] DRY-RUN\n'
fi
EOF

  cat >"${scripts_dir}/dispatch-review-merge-hardened.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"${scripts_dir}/dispatch-loop-hardened.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"${scripts_dir}/ccc-headless-task.sh" <<'EOF'
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
[ "${ANTHROPIC_API_KEY:-}" = "mock-anthropic-test-key-12345" ] || {
  printf 'missing ANTHROPIC_API_KEY\n' >&2
  exit 97
}
printf '%s\n' '[{"session_id":"review-session-1","total_cost_usd":0.44,"result":"PR #1 MERGE_STATUS: merged\nPR #1 MERGED_SHA: cafe1234\nPR #2 MERGE_STATUS: skipped_non_pass\nPR #2 MERGED_SHA: none\nPR #3 MERGE_STATUS: skipped_non_pass\nPR #3 MERGED_SHA: none\nBATCH_STATUS: partial"}]'
EOF

  chmod +x \
    "${scripts_dir}/dispatch-pre.sh" \
    "${scripts_dir}/dispatch-review-merge-hardened.sh" \
    "${scripts_dir}/dispatch-loop-hardened.sh" \
    "${scripts_dir}/ccc-headless-task.sh" \
    "${dir}/bin/gh" \
    "${dir}/bin/pgrep" \
    "${dir}/bin/id" \
    "${dir}/bin/getent" \
    "${dir}/bin/sudo" \
    "${dir}/bin/claude"

  setup_worker_home "$dir" "${prefix}-w1"
  setup_worker_home "$dir" "${prefix}-w2"
  setup_worker_home "$dir" "${prefix}-w3"

  printf '%s\n' "$dispatch_home" >"${dir}/dispatch-home.txt"
}

base_env() {
  local dir="$1" dispatch_home=""
  dispatch_home="$(<"${dir}/dispatch-home.txt")"
  printf '%s\0' \
    "PATH=${dir}/bin:${PATH}" \
    "DISPATCH_HOME=${dispatch_home}" \
    "DISPATCH_BATCH_ANTHROPIC_KEY_FILE=${dispatch_home}/.config/anthropic-api-key" \
    "DISPATCH_BATCH_STAGGER_SEC=0" \
    "DISPATCH_BATCH_TEST_HOME_ROOT=${dir}/home" \
    "GITHUB_TOKEN=dummy-token"
}

run_case_missing_dispatch_home() {
  local dir stdout_file stderr_file
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  mkdir -p "${dir}/manifests"
  printf '# worker 1\n' >"${dir}/manifests/worker-w1.md"
  printf '# review template\n' >"${dir}/review.md"

  run_capture "$stdout_file" "$stderr_file" bash "$SCRIPT" \
    --dry-run \
    --project-prefix batchok \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md"

  assert_status "$RUN_STATUS" 1 "missing-dispatch-home"
  assert_contains "$stderr_file" "DISPATCH_HOME must be set" "missing-dispatch-home"
}

run_case_dry_run() {
  local dir stdout_file stderr_file prefix
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  prefix="$(slug_from_dir "$dir" batch)"
  setup_fixture "$dir" "$prefix"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --project-prefix "$prefix" \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --dry-run

  assert_status "$RUN_STATUS" 0 "dry-run"
  jq -e --arg prefix "$prefix" '.batch_prefix == $prefix and .n_workers == 3 and (.results_per_worker | length) == 3' "$stdout_file" >/dev/null \
    || fail "dry-run: invalid JSON summary"
}

run_case_missing_project_prefix() {
  local dir stdout_file stderr_file
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  setup_fixture "$dir" "$(slug_from_dir "$dir" batch)"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --dry-run

  assert_status "$RUN_STATUS" 1 "missing-project-prefix"
  assert_contains "$stderr_file" "--project-prefix is required." "missing-project-prefix"
}

run_case_missing_manifests_dir() {
  local dir stdout_file stderr_file
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  setup_fixture "$dir" "$(slug_from_dir "$dir" batch)"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --project-prefix batchok \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --dry-run

  assert_status "$RUN_STATUS" 1 "missing-manifests-dir"
  assert_contains "$stderr_file" "--manifests-dir is required." "missing-manifests-dir"
}

run_case_empty_manifests_dir() {
  local dir stdout_file stderr_file prefix
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  prefix="$(slug_from_dir "$dir" batch)"
  setup_fixture "$dir" "$prefix"
  rm -f "${dir}/manifests/"*.md

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --project-prefix "$prefix" \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --dry-run

  assert_status "$RUN_STATUS" 1 "empty-manifests-dir"
  assert_contains "$stderr_file" "No worker manifests found" "empty-manifests-dir"
}

run_case_b29() {
  local dir stdout_file stderr_file
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  setup_fixture "$dir" "$(slug_from_dir "$dir" batch)"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --project-prefix abcdefghijklmnopqrstuvw \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --dry-run

  assert_status "$RUN_STATUS" 1 "b29"
  assert_contains "$stderr_file" "B29" "b29"
}

run_case_verdict_parsing() {
  local dir stdout_file stderr_file dispatch_home prefix
  dir="$(mktemp -d)"
  stdout_file="${dir}/stdout.json"
  stderr_file="${dir}/stderr.log"
  prefix="$(slug_from_dir "$dir" batch)"
  setup_fixture "$dir" "$prefix"
  dispatch_home="$(<"${dir}/dispatch-home.txt")"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$stdout_file" "$stderr_file" env "${env_args[@]}" bash "$SCRIPT" \
    --project-prefix "$prefix" \
    --manifests-dir "${dir}/manifests" \
    --target-repo-template 'owner/repo-{N}' \
    --review-prompt-file "${dir}/review.md" \
    --mode auto

  assert_status "$RUN_STATUS" 12 "verdict-parsing"
  jq -e '
    .status == "partial" and
    (.results_per_worker[] | select(.worker == "w1") | .verdict == "PASS" and .status == "merged" and .merged_sha == "cafe1234") and
    (.results_per_worker[] | select(.worker == "w2") | .verdict == "WARN" and .status == "skipped") and
    (.results_per_worker[] | select(.worker == "w3") | .verdict == "FAIL" and .status == "skipped")
  ' "$stdout_file" >/dev/null || fail "verdict-parsing: summary mismatch"
  assert_contains "$stderr_file" "final=${dispatch_home}/.codex-headless/${prefix}-w1/w1/final-20260501.txt" "verdict-parsing"
}

main() {
  run_case_missing_dispatch_home
  run_case_dry_run
  run_case_missing_project_prefix
  run_case_missing_manifests_dir
  run_case_empty_manifests_dir
  run_case_b29
  run_case_verdict_parsing
  printf 'PASS: test-dispatch-batch.sh\n'
}

main "$@"
