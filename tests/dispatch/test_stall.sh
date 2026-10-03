#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_brief silent.md $'# Task\nBLOCK_SILENT\n'
make_brief files.md $'# Task\nPROGRESS_SILENT\n'
make_brief burn.md $'# Task\nBURN_CPU\n'

CPU_PROBE="$TEST_ROOT/cpu-probe.sh"
cat >"$CPU_PROBE" <<'PROBE'
set -Eeuo pipefail
source "$1/scripts/lib/dispatch-common.sh"
source "$1/scripts/lib/dispatch-quota.sh"
source "$1/scripts/lib/dispatch-wait.sh"
printf '10 0:01.50\n10 1:02:03.25\n10 2-01:00:00.00\n11 5:00.00\n' | dd_sum_cpu_times 10
printf '12 0:00.00\n' | dd_sum_cpu_times 99
PROBE
capture "$BASH" "$CPU_PROBE" "$REPO_DIR"
assert_eq 'CPU times in minute, hour, and day formats are summed per process group' \
  $'180124.75' "$OUTPUT"

use_spy_cli
new_silent_block quiet
next_session
dispatch run --session "$SESSION" --label stalled --role general-purpose --model sonnet --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/silent.md" --wait --poll-seconds 1 --stall-timeout 2 --max-wait 60
worker="$(receipt_worker "$OUTPUT")"
idle="$(sed -n "s/^GLM_STALLED label=stalled worker=$worker idle_seconds=\([0-9]*\)\$/\1/p" <<<"$OUTPUT")"
assert_eq 'a worker with no progress signal exits 12' 12 "$RC"
if [[ -n "$idle" ]] && ((idle >= 2)); then
  pass 'GLM_STALLED reports idle seconds of at least the stall timeout'
else
  fail 'GLM_STALLED reports idle seconds of at least the stall timeout' "output=[$OUTPUT]"
fi
assert_not_contains 'a stalled wait prints no verdict' "$OUTPUT" GLM_VERDICT
assert_contains 'a stalled worker is not cancelled' \
  "$("$REAL_CLI" status "$worker")" 'STATUS=RUNNING'
provider_pgid="$(kv_file_get "$GLM_AGENT_HOME/workers/$worker/active/state" provider_pgid)"
if [[ "$provider_pgid" =~ ^[1-9][0-9]*$ ]]; then
  pass 'the active state of a running worker exposes provider_pgid'
else
  fail 'the active state of a running worker exposes provider_pgid' "got [$provider_pgid]"
fi
release_silent_block
wait_terminal "$worker"

new_silent_block quiet2
next_session
dispatch run --session "$SESSION" --label unlimited --role general-purpose --model sonnet --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/silent.md" --wait --poll-seconds 1 --stall-timeout 0 --max-wait 4
worker="$(receipt_worker "$OUTPUT")"
assert_eq '--stall-timeout 0 disables stall detection' 13 "$RC"
assert_contains 'with stall detection off the max-wait line is printed' "$OUTPUT" GLM_STILL_RUNNING
release_silent_block
wait_terminal "$worker"

use_spy_cli
new_silent_block files
next_session
out_file="$TEST_ROOT/files.out"
"$BASH" "$DISPATCH" run --session "$SESSION" --label files --role general-purpose --model sonnet --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/files.md" --wait --poll-seconds 1 --stall-timeout 2 >"$out_file" 2>&1 &
pid=$!
wait_for_file "$FAKE_CLAUDE_BLOCK_STARTED"
wait_for_lines "$SPY_LOG" 5 || true
release_silent_block
rc=0
wait "$pid" || rc=$?
assert_eq 'a worker whose turn files keep changing is not judged stalled' 0 "$rc"
assert_not_contains 'a changing worker prints no GLM_STALLED line' "$(cat "$out_file")" GLM_STALLED
assert_contains 'a changing worker still reaches its verdict' "$(cat "$out_file")" 'status=DONE'

use_spy_cli
new_block burn
next_session
out_file="$TEST_ROOT/burn.out"
"$BASH" "$DISPATCH" run --session "$SESSION" --label burn --role general-purpose --model sonnet --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/burn.md" --wait --poll-seconds 1 --stall-timeout 2 >"$out_file" 2>&1 &
pid=$!
wait_for_file "$FAKE_CLAUDE_BLOCK_STARTED"
wait_for_lines "$SPY_LOG" 5 || true
release_block
rc=0
wait "$pid" || rc=$?
assert_eq 'a worker that only burns CPU is not judged stalled' 0 "$rc"
assert_not_contains 'a CPU-bound worker prints no GLM_STALLED line' "$(cat "$out_file")" GLM_STALLED

finish
