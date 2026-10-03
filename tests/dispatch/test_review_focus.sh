#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGISTRY="$GLM_AGENT_HOME/dispatch"
ROLE_FLAGS=(--role general-purpose --model sonnet)

make_brief plain.md $'# Task\nplain work\n'
make_brief block.md $'# Task\nWAIT_FOR_RELEASE\n'
make_brief silent.md $'# Task\nBLOCK_SILENT\n'
make_brief touch.md $'# Task\nTOUCH_TRACKED\n'
printf -- '--foo\nbody line\n' >"$TEST_ROOT/dash-long.md"
printf -- '-h\n' >"$TEST_ROOT/dash-h.md"
printf -- '- bullet one\n- bullet two\n' >"$TEST_ROOT/dash-bullet.md"

same_bytes() {
  if cmp -s "$1" "$2"; then
    printf 'same'
  else
    printf 'differ'
  fi
}

settle_worker() {
  if [[ -n "$1" ]]; then
    wait_terminal "$1"
  fi
}

cli_call_files() {
  find "$FAKE_CLI_DIR" -name '*.argv' | wc -l | tr -d ' '
}

use_fake_cli
fake_cli_set quota "$(fake_quota_healthy)"
fake_cli_set start "$(fake_receipt w-r1 1 sonnet general-purpose RUNNING)"
fake_cli_set send "$(fake_receipt w-r1 2 sonnet general-purpose RUNNING)"
fake_worker_meta w-r1 general-purpose sonnet "$PROJECT"
for name in dash-long dash-h dash-bullet; do
  next_session
  dispatch run --session "$SESSION" --label "$name" "${ROLE_FLAGS[@]}" --cwd "$PROJECT" \
    --task-file "$TEST_ROOT/$name.md"
  { printf '\n'; cat "$TEST_ROOT/$name.md"; } >"$TEST_ROOT/$name.expected"
  assert_eq "R1 run with a brief starting with a dash ($name) succeeds with a receipt" \
    "0|GLM_RECEIPT label=$name worker=w-r1 turn=1 role=general-purpose model=sonnet cwd=$PROJECT scope=personal quota_5h_used=2789 quota_1w_used=37560" \
    "$RC|$OUTPUT"
  assert_eq "R1 the CLI receives one newline byte and then the brief ($name)" same \
    "$(same_bytes "$FAKE_CLI_DIR/start.lastarg" "$TEST_ROOT/$name.expected")"
done
dispatch send --session "$SESSION" --label dash-bullet --task-file "$TEST_ROOT/dash-bullet.md"
assert_eq 'R1 send with a brief starting with a dash succeeds with a receipt' 0 "$RC"
assert_eq 'R1 send passes one newline byte and then the brief to the CLI' same \
  "$(same_bytes "$FAKE_CLI_DIR/send.lastarg" "$TEST_ROOT/dash-bullet.expected")"
next_session
dispatch run --session "$SESSION" --label nodash "${ROLE_FLAGS[@]}" --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/plain.md"
assert_eq 'R1 a brief not starting with a dash gets no leading newline' same \
  "$(same_bytes "$FAKE_CLI_DIR/start.lastarg" "$TEST_ROOT/plain.md")"

use_real_cli
for name in dash-long dash-h dash-bullet; do
  next_session
  dispatch run --session "$SESSION" --label "$name" "${ROLE_FLAGS[@]}" --cwd "$PROJECT" \
    --task-file "$TEST_ROOT/$name.md"
  assert_contains "R1 the real CLI starts a worker for a brief starting with a dash ($name)" \
    "$OUTPUT" "GLM_RECEIPT label=$name "
  settle_worker "$(receipt_worker "$OUTPUT")"
  assert_eq "R1 claude receives the brief behind a leading newline ($name)" \
    $'\n'"$(cat "$TEST_ROOT/$name.md")" "$(cat "$FAKE_CLAUDE_PROMPT_FILE")"
done

use_fake_cli
fake_cli_set quota "$(fake_quota_healthy)"
fake_cli_set start "$(fake_receipt w-r2 1 sonnet general-purpose RUNNING)"
fake_cli_set send "$(fake_receipt w-r2 2 sonnet general-purpose RUNNING)"
fake_worker_meta w-r2 general-purpose sonnet "$PROJECT"
head -c 262145 /dev/zero | tr '\0' x >"$TEST_ROOT/over.md"
head -c 262144 /dev/zero | tr '\0' x >"$TEST_ROOT/limit.md"
TOO_LARGE='glm-dispatch: task-file too large (max 262144 bytes)'
next_session
dispatch run --session "$SESSION" --label over "${ROLE_FLAGS[@]}" --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/over.md"
assert_eq 'R2 oversized task-file exits 2 before quota and start' \
  "2||$TOO_LARGE" "$RC|$OUTPUT|$STDERR"
assert_eq 'R2 oversized task-file makes no CLI call' 0 "$(cli_call_files)"
assert_no_file 'R2 oversized task-file writes no registry entry' "$REGISTRY/$SESSION/over.env"
dispatch run --session "$SESSION" --label limit "${ROLE_FLAGS[@]}" --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/limit.md"
assert_eq 'R2 a task-file of exactly 262144 bytes is accepted' \
  "0|GLM_RECEIPT label=limit worker=w-r2 turn=1 role=general-purpose model=sonnet cwd=$PROJECT scope=personal quota_5h_used=2789 quota_1w_used=37560" \
  "$RC|$OUTPUT"
assert_eq 'R2 the accepted brief reaches the CLI start byte for byte' same \
  "$(same_bytes "$FAKE_CLI_DIR/start.lastarg" "$TEST_ROOT/limit.md")"
send_calls="$(fake_cli_calls send)"
dispatch send --session "$SESSION" --label limit --task-file "$TEST_ROOT/over.md"
assert_eq 'R2 send rejects an oversized task-file the same way' \
  "2||$TOO_LARGE" "$RC|$OUTPUT|$STDERR"
assert_eq 'R2 a rejected send never calls the CLI send' "$send_calls" "$(fake_cli_calls send)"

use_real_cli
SPACE_DIR="$TEST_ROOT/dir with space"
mkdir -p "$SPACE_DIR"
SPACE_REAL="$(cd "$SPACE_DIR" && pwd -P)"
SPACE_ENCODED="${SPACE_REAL// /%20}"
ln -s "$SPACE_DIR" "$TEST_ROOT/link with space"
make_brief "brief \$x.md" $'# Task\nspaced brief\n'
SPACE_BRIEF="$BRIEF"
next_session
dispatch run --session "$SESSION" --label spaced "${ROLE_FLAGS[@]}" \
  --cwd "$TEST_ROOT/link with space" --task-file "$SPACE_BRIEF"
spaced_worker="$(receipt_worker "$OUTPUT")"
assert_eq 'R3 receipt cwd is the real path with each space encoded as %20' \
  "0|GLM_RECEIPT label=spaced worker=$spaced_worker turn=1 role=general-purpose model=sonnet cwd=$SPACE_ENCODED scope=personal quota_5h_used=2789 quota_1w_used=37560" \
  "$RC|$OUTPUT"
settle_worker "$spaced_worker"
assert_eq 'R3 registry cwd uses the same %20 encoding as the receipt' \
  "$SPACE_ENCODED" "$(kv_file_get "$REGISTRY/$SESSION/spaced.env" cwd)"
assert_eq 'R3 registry task_file keeps the dollar sign and the space' \
  "$SPACE_BRIEF" "$(kv_file_get "$REGISTRY/$SESSION/spaced.env" task_file)"
assert_eq 'R3 worker meta cwd is the real path' "$SPACE_REAL" \
  "$(kv_file_get "$GLM_AGENT_HOME/workers/$spaced_worker/meta" cwd)"
assert_eq 'R3 claude receives the brief from a path with a space and a dollar sign' \
  "$(cat "$SPACE_BRIEF")" "$(cat "$FAKE_CLAUDE_PROMPT_FILE")"
dispatch send --session "$SESSION" --label spaced --task-file "$TEST_ROOT/plain.md" \
  --wait --poll-seconds 1
assert_contains 'R3 send reads the encoded cwd back and passes the receipt check' \
  "$OUTPUT" "GLM_RECEIPT label=spaced worker=$spaced_worker turn=2 role=general-purpose model=sonnet cwd=$SPACE_ENCODED "
assert_contains 'R3 send reaches its verdict' "$OUTPUT" ' status=DONE '

SPACE_GIT="$TEST_ROOT/git dir with space"
make_git_project "$SPACE_GIT"
next_session
dispatch run --session "$SESSION" --label spacegit --role explorer --model sonnet \
  --cwd "$SPACE_GIT" --task-file "$TEST_ROOT/touch.md" --wait --poll-seconds 1
assert_contains 'R3 the git change list works in a cwd with a space' \
  "$OUTPUT" 'GLM_WARN explorer_modified files=tracked.txt'
assert_contains 'R3 files_changed counts the change in a cwd with a space' "$OUTPUT" ' files_changed=1 '

use_real_cli
next_session
new_block r4a
out_a="$TEST_ROOT/r4a.out"
"$BASH" "$DISPATCH" run --session "$SESSION" --label a "${ROLE_FLAGS[@]}" --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/block.md" --wait --poll-seconds 1 >"$out_a" 2>&1 &
pid_a=$!
wait_for_text "$out_a" GLM_RECEIPT
wait_for_file "$FAKE_CLAUDE_BLOCK_STARTED"
release_a="$FAKE_CLAUDE_BLOCK_RELEASE"
new_block r4b
out_b="$TEST_ROOT/r4b.out"
"$BASH" "$DISPATCH" run --session "$SESSION" --label b "${ROLE_FLAGS[@]}" --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/block.md" --wait --poll-seconds 1 >"$out_b" 2>&1 &
pid_b=$!
wait_for_text "$out_b" GLM_RECEIPT
wait_for_file "$FAKE_CLAUDE_BLOCK_STARTED"
release_b="$FAKE_CLAUDE_BLOCK_RELEASE"
worker_a="$(receipt_worker "$(cat "$out_a")")"
worker_b="$(receipt_worker "$(cat "$out_b")")"
if [[ -n "$worker_a" && -n "$worker_b" && "$worker_a" != "$worker_b" ]]; then
  pass 'R4 two labels of one session start two distinct workers'
else
  fail 'R4 two labels of one session start two distinct workers' "a=[$worker_a] b=[$worker_b]"
fi
assert_eq 'R4 registry file a.env holds only the first worker' \
  "a|$worker_a" "$(kv_file_get "$REGISTRY/$SESSION/a.env" label)|$(kv_file_get "$REGISTRY/$SESSION/a.env" worker_id)"
assert_eq 'R4 registry file b.env holds only the second worker' \
  "b|$worker_b" "$(kv_file_get "$REGISTRY/$SESSION/b.env" label)|$(kv_file_get "$REGISTRY/$SESSION/b.env" worker_id)"
dispatch pending --session "$SESSION"
assert_eq 'R4 pending lists both running labels' \
  "0|GLM_PENDING label=a worker=$worker_a state=running status=RUNNING"$'\n'"GLM_PENDING label=b worker=$worker_b state=running status=RUNNING" \
  "$RC|$OUTPUT"
: >"$release_b"
rc=0
wait "$pid_b" || rc=$?
assert_eq 'R4 label b finishes first with exit 0' 0 "$rc"
assert_contains 'R4 label b prints its own verdict' "$(cat "$out_b")" \
  "GLM_VERDICT label=b worker=$worker_b status=DONE "
assert_not_contains 'R4 label b prints nothing of worker a' "$(cat "$out_b")" "worker=$worker_a"
assert_not_contains 'R4 label a has no verdict while its worker still runs' "$(cat "$out_a")" GLM_VERDICT
: >"$release_a"
rc=0
wait "$pid_a" || rc=$?
assert_eq 'R4 label a finishes second with exit 0' 0 "$rc"
assert_contains 'R4 label a prints its own verdict' "$(cat "$out_a")" \
  "GLM_VERDICT label=a worker=$worker_a status=DONE "
assert_not_contains 'R4 label a prints nothing of worker b' "$(cat "$out_a")" "worker=$worker_b"

use_real_cli
next_session
new_block r5
out_file="$TEST_ROOT/r5.out"
"$BASH" "$DISPATCH" run --session "$SESSION" --label killed "${ROLE_FLAGS[@]}" --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/block.md" --wait --poll-seconds 1 >"$out_file" 2>&1 &
pid=$!
wait_for_text "$out_file" GLM_RECEIPT
wait_for_file "$FAKE_CLAUDE_BLOCK_STARTED"
kill -TERM "$pid"
rc=0
wait "$pid" || rc=$?
killed_worker="$(receipt_worker "$(cat "$out_file")")"
assert_eq 'R5 SIGTERM stops the waiting dispatch process' 143 "$rc"
assert_eq 'R5 the registry keeps the worker id after the wait process is killed' \
  "$killed_worker" "$(kv_file_get "$REGISTRY/$SESSION/killed.env" worker_id)"
assert_contains 'R5 the worker keeps running after the wait process is killed' \
  "$("$REAL_CLI" status "$killed_worker")" 'STATUS=RUNNING'
: >"$FAKE_CLAUDE_BLOCK_RELEASE"
dispatch attach --session "$SESSION" --label killed --poll-seconds 1
assert_contains 'R5 attach after the kill reaches the verdict' "$OUTPUT" \
  "GLM_VERDICT label=killed worker=$killed_worker status=DONE "
assert_eq 'R5 attach exits 0 for a DONE worker' 0 "$RC"

use_fake_cli
fake_cli_set quota "$(fake_quota_healthy)"
next_session
dispatch run --session "$SESSION" --label norole --model sonnet --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/plain.md"
assert_eq 'R6 run without --role exits 2' \
  "2||glm-dispatch: --role is required" "$RC|$OUTPUT|$STDERR"
dispatch run --session "$SESSION" --label nomodel --role general-purpose --cwd "$PROJECT" \
  --task-file "$TEST_ROOT/plain.md"
assert_eq 'R6 run without --model exits 2' \
  "2||glm-dispatch: --model is required" "$RC|$OUTPUT|$STDERR"
dispatch run --session "$SESSION" --label nocwd "${ROLE_FLAGS[@]}" --task-file "$TEST_ROOT/plain.md"
assert_eq 'R6 run without --cwd exits 2' \
  "2||glm-dispatch: --cwd is required" "$RC|$OUTPUT|$STDERR"
dispatch_in "$PROJECT" run --session "$SESSION" --label nocwd2 "${ROLE_FLAGS[@]}" \
  --task-file "$TEST_ROOT/plain.md"
assert_eq 'R6 run does not fall back to the current directory' \
  "2||glm-dispatch: --cwd is required" "$RC|$OUTPUT|$STDERR"
assert_eq 'R6 a rejected run makes no CLI call' 0 "$(cli_call_files)"

use_real_cli
GOOD_PATH="$PATH"
FAILING_PS_DIR="$TEST_ROOT/failing-ps-bin"
PS_CALLS="$TEST_ROOT/ps.calls"
mkdir -p "$FAILING_PS_DIR"
: >"$PS_CALLS"
cat >"$FAILING_PS_DIR/ps" <<PS
#!/bin/sh
printf 'x\n' >>"$PS_CALLS"
exit 1
PS
chmod +x "$FAILING_PS_DIR/ps"
cat >"$FAKE_BIN/clean-path-cli" <<CLI
#!/usr/bin/env bash
PATH="$GOOD_PATH" exec "$REAL_CLI" "\$@"
CLI
chmod +x "$FAKE_BIN/clean-path-cli"
export GLM_DISPATCH_CLI="$FAKE_BIN/clean-path-cli"
new_silent_block nocpu
next_session
capture env "PATH=$FAILING_PS_DIR:$GOOD_PATH" "$BASH" "$DISPATCH" run --session "$SESSION" \
  --label nocpu "${ROLE_FLAGS[@]}" --cwd "$PROJECT" --task-file "$TEST_ROOT/silent.md" \
  --wait --poll-seconds 1 --stall-timeout 2 --max-wait 6
nocpu_worker="$(receipt_worker "$OUTPUT")"
assert_eq 'R7 static files without a readable CPU time end at max-wait with exit 13' 13 "$RC"
assert_contains 'R7 the unreadable CPU time ends in GLM_STILL_RUNNING' "$OUTPUT" \
  "GLM_STILL_RUNNING label=nocpu worker=$nocpu_worker waited_seconds="
assert_not_contains 'R7 the unreadable CPU time prints no GLM_STALLED line' "$OUTPUT" GLM_STALLED
assert_eq 'R7 the failing ps was consulted' 1 "$([[ -s "$PS_CALLS" ]] && printf 1 || printf 0)"
assert_contains 'R7 the worker keeps running after max-wait' \
  "$("$REAL_CLI" status "$nocpu_worker")" 'STATUS=RUNNING'
release_silent_block
settle_worker "$nocpu_worker"

finish
