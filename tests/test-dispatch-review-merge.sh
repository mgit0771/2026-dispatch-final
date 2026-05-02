#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/dispatch-review-merge-hardened.sh"

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
  local outfile="$1"
  shift
  set +e
  "$@" >"$outfile" 2>&1
  RUN_STATUS=$?
  set -e
}

setup_fixture() {
  local dir="$1" dispatch_home="${dir}/dispatcher-test"

  mkdir -p \
    "${dispatch_home}/dispatch/scripts" \
    "${dispatch_home}/repos" \
    "${dispatch_home}/.codex-headless" \
    "${dispatch_home}/.ccc-headless" \
    "${dispatch_home}/logs" \
    "${dispatch_home}/registries" \
    "${dispatch_home}/.config"
  printf '# review\n' >"${dir}/review.md"
  printf 'mock-anthropic-test-key-12345\n' >"${dispatch_home}/.config/anthropic-api-key"
  chmod 600 "${dispatch_home}/.config/anthropic-api-key"
  printf '%s\n' "$dispatch_home" >"${dir}/dispatch-home.txt"
}

base_env() {
  local dir="$1" dispatch_home=""
  dispatch_home="$(<"${dir}/dispatch-home.txt")"
  printf '%s\0' \
    "DISPATCH_HOME=${dispatch_home}" \
    "DISPATCH_REVIEW_MERGE_ANTHROPIC_KEY_FILE=${dispatch_home}/.config/anthropic-api-key"
}

run_case_missing_dispatch_home() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  printf '# review\n' >"${dir}/review.md"

  run_capture "$out" bash "$SCRIPT" \
    --dry-run \
    --project reviewnodispatchhome \
    --worker-name w1 \
    --target-repo mgit0771/dummy \
    --review-prompt-file "${dir}/review.md"

  assert_status "$RUN_STATUS" 1 "missing-dispatch-home"
  assert_contains "$out" "DISPATCH_HOME must be set" "missing-dispatch-home"
}

run_case_dry_run() {
  local dir out dispatch_home
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"
  dispatch_home="$(<"${dir}/dispatch-home.txt")"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$out" env "${env_args[@]}" bash "$SCRIPT" \
    --dry-run \
    --project reviewdryrunproj \
    --worker-name w1 \
    --target-repo mgit0771/dummy \
    --review-prompt-file "${dir}/review.md"

  assert_status "$RUN_STATUS" 0 "dry-run"
  assert_contains "$out" "Phase 7 (wait worker DONE): DRY-RUN" "dry-run"
  assert_contains "$out" "worker_final=${dispatch_home}/.codex-headless/reviewdryrunproj/w1/final-DRY-RUN.txt" "dry-run"
  assert_contains "$out" "review_verdict=PASS" "dry-run"
}

run_case_missing_project() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$out" env "${env_args[@]}" bash "$SCRIPT" \
    --dry-run \
    --target-repo mgit0771/dummy \
    --review-prompt-file "${dir}/review.md"

  assert_status "$RUN_STATUS" 1 "missing-project"
  assert_contains "$out" "--project is required." "missing-project"
}

run_case_missing_review_prompt() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$out" env "${env_args[@]}" bash "$SCRIPT" \
    --dry-run \
    --project reviewmissingprompt \
    --target-repo mgit0771/dummy

  assert_status "$RUN_STATUS" 1 "missing-review"
  assert_contains "$out" "--review-prompt-file is required." "missing-review"
}

run_case_nonabsolute_review_prompt() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$out" env "${env_args[@]}" bash -lc "
    cd '${dir}' &&
    bash '${SCRIPT}' \
      --dry-run \
      --project reviewrelativeprompt \
      --target-repo mgit0771/dummy \
      --review-prompt-file review.md
  "

  assert_status "$RUN_STATUS" 1 "nonabsolute-review"
  assert_contains "$out" "must be an absolute path" "nonabsolute-review"
}

main() {
  run_case_missing_dispatch_home
  run_case_dry_run
  run_case_missing_project
  run_case_missing_review_prompt
  run_case_nonabsolute_review_prompt
  printf 'PASS: test-dispatch-review-merge.sh\n'
}

main "$@"
