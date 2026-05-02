#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/dispatch-pre.sh"

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
    "${dispatch_home}/.config" \
    "${dir}/bin"
  printf '# dummy\n' >"${dir}/dummy.md"
  printf 'secret=%s\n' "ghp_$(printf '%025d' 0)" >"${dir}/secret.md"
  printf 'mock-codex-test-key-12345\n' >"${dispatch_home}/.config/codex-api-key"
  printf 'mock-anthropic-test-key-12345\n' >"${dispatch_home}/.config/anthropic-api-key"
  chmod 600 "${dispatch_home}/.config/codex-api-key" "${dispatch_home}/.config/anthropic-api-key"

  cat >"${dir}/bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '1000\n'
  exit 0
fi
exec /usr/bin/id "$@"
EOF
  chmod +x "${dir}/bin/id"

  printf '%s\n' "$dispatch_home" >"${dir}/dispatch-home.txt"
}

base_env() {
  local dir="$1" dispatch_home=""
  dispatch_home="$(<"${dir}/dispatch-home.txt")"
  printf '%s\0' \
    "DISPATCH_HOME=${dispatch_home}" \
    "PATH=${dir}/bin:${PATH}"
}

run_case_missing_dispatch_home() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  printf '# dummy\n' >"${dir}/dummy.md"

  run_capture "$out" bash "$SCRIPT" \
    --dry-run \
    --project test-dryrun \
    --manifest-file "${dir}/dummy.md" \
    --target-repo mgit0771/dummy

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
    --project test-dryrun \
    --manifest-file "${dir}/dummy.md" \
    --target-repo mgit0771/dummy

  assert_status "$RUN_STATUS" 0 "dry-run"
  assert_contains "$out" "Phase 0 (pre-flight): OK (dry-run, privileged checks skipped)" "dry-run"
  assert_contains "$out" "Phase 7 (verify): DRY-RUN, would inspect ${dispatch_home}/.codex-headless/test-dryrun/w1/run-*.log" "dry-run"
}

run_case_missing_project() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$out" env "${env_args[@]}" bash "$SCRIPT" \
    --dry-run \
    --manifest-file "${dir}/dummy.md" \
    --target-repo mgit0771/dummy

  assert_status "$RUN_STATUS" 1 "missing-project"
  assert_contains "$out" "--project is required." "missing-project"
}

run_case_secret_scan() {
  local dir out
  dir="$(mktemp -d)"
  out="${dir}/out.txt"
  setup_fixture "$dir"

  mapfile -d '' -t env_args < <(base_env "$dir")
  run_capture "$out" env "${env_args[@]}" bash "$SCRIPT" \
    --dry-run \
    --project test-dryrun \
    --manifest-file "${dir}/secret.md" \
    --target-repo mgit0771/dummy

  assert_status "$RUN_STATUS" 3 "secret-scan"
  assert_contains "$out" "B27 detection" "secret-scan"
}

main() {
  run_case_missing_dispatch_home
  run_case_dry_run
  run_case_missing_project
  run_case_secret_scan
  printf 'PASS: test-dispatch-pre.sh\n'
}

main "$@"
