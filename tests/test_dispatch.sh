#!/usr/bin/env bash
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
LOG_DIR="$(mktemp -d "$TEMP_BASE/glm-dispatch-runner.XXXXXX")"

cleanup() {
  rm -rf "$LOG_DIR"
}
trap cleanup EXIT

total=0
failed=0
for test_file in "$TESTS_DIR"/dispatch/test_*.sh; do
  name="${test_file##*/}"
  printf '# %s\n' "$name"
  rc=0
  "$BASH" "$test_file" >"$LOG_DIR/out" 2>&1 || rc=$?
  cat "$LOG_DIR/out"
  count="$(sed -n 's/^1\.\.\([0-9]*\)$/\1/p' "$LOG_DIR/out" | tail -n 1)"
  total=$((total + ${count:-0}))
  if ((rc != 0)); then
    failed=$((failed + 1))
    printf '# FAILED: %s (exit %d)\n' "$name" "$rc"
  fi
done

printf '1..%d\n' "$total"
if ((failed > 0)); then
  printf '# %d test file(s) failed\n' "$failed" >&2
  exit 1
fi
printf '# all %d tests passed\n' "$total"
