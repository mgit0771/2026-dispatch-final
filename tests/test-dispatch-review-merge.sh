#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; SCRIPT="$ROOT/scripts/dispatch-review-merge.sh"; TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
printf '# review\n' >"$TMPDIR/review.md"
OUT="$(bash "$SCRIPT" --dry-run --project test-dryrun --worker-name w1 --target-repo mgit0771/dummy --review-prompt-file "$TMPDIR/review.md" 2>&1)"; [[ "$OUT" == *"DRY-RUN"* && "$OUT" == *"review_verdict=PASS"* ]]
set +e; bash "$SCRIPT" --dry-run --target-repo mgit0771/dummy --review-prompt-file "$TMPDIR/review.md" >"$TMPDIR/missing-project.out" 2>&1; STATUS=$?; set -e; [ "$STATUS" -eq 1 ] && grep -q -- "--project is required" "$TMPDIR/missing-project.out"
set +e; bash "$SCRIPT" --dry-run --project test-dryrun --target-repo mgit0771/dummy >"$TMPDIR/missing-review.out" 2>&1; STATUS=$?; set -e; [ "$STATUS" -eq 1 ] && grep -q -- "--review-prompt-file is required" "$TMPDIR/missing-review.out"
printf '# review\n' >"$TMPDIR/relative.md"
set +e; (cd "$TMPDIR" && bash "$SCRIPT" --dry-run --project test-dryrun --target-repo mgit0771/dummy --review-prompt-file relative.md >"$TMPDIR/nonabsolute.out" 2>&1); STATUS=$?; set -e; [ "$STATUS" -eq 1 ] && grep -q "must be an absolute path" "$TMPDIR/nonabsolute.out"
