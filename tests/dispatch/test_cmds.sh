#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_brief quick.md $'# Task\nquick work\n'
make_brief followup.md $'# Task\nfollow-up work\nsecond line\n\n'
make_brief block.md $'# Task\nWAIT_FOR_RELEASE\n'
make_brief silent.md $'# Task\nBLOCK_SILENT\n'
make_brief create.md $'# Task\nCREATE_FILE\n'
make_brief touch.md $'# Task\nTOUCH_TRACKED\n'
REGISTRY="$GLM_AGENT_HOME/dispatch"

start_label() {
  local label="$1" brief="$2"
  shift 2
  dispatch run --session "$SESSION" --label "$label" --role general-purpose --model sonnet --cwd "$PROJECT" \
    --task-file "$TEST_ROOT/$brief" "$@"
  WORKER="$(receipt_worker "$OUTPUT")"
}

reg_get() {
  kv_file_get "$REGISTRY/$SESSION/$1.env" "$2"
}

use_real_cli
next_session
for sub in send attach ack status result cancel close; do
  extra=()
  if [[ "$sub" == send ]]; then
    extra=(--task-file "$TEST_ROOT/quick.md")
  fi
  dispatch "$sub" --session "$SESSION" --label nope ${extra[@]+"${extra[@]}"}
  assert_eq "$sub on an unknown label exits 2 with one stderr line" \
    "2||glm-dispatch: label not found: nope" "$RC|$OUTPUT|$STDERR"
done

start_label first quick.md --role explorer --model haiku
wait_terminal "$WORKER"
first_worker="$WORKER"
dispatch ack --session "$SESSION" --label first
assert_eq 'ack on a terminal worker acknowledges it' "0|GLM_ACK label=first" "$RC|$OUTPUT"
assert_eq 'ack records acked=true' true "$(reg_get first acked)"
dispatch send --session "$SESSION" --label first --task-file "$TEST_ROOT/followup.md" \
  --wait --poll-seconds 1
assert_contains 'send prints a receipt for turn 2 with the registered role and model' \
  "$OUTPUT" "GLM_RECEIPT label=first worker=$first_worker turn=2 role=explorer model=haiku cwd=$PROJECT "
assert_contains 'send --wait reaches a DONE verdict' "$OUTPUT" ' status=DONE '
assert_eq 'send exits 0 for a DONE worker' 0 "$RC"
assert_eq 'send updates the registry turn' 2 "$(reg_get first turn)"
assert_eq 'send resets acked to false' false "$(reg_get first acked)"
assert_eq 'claude receives the follow-up brief' "$(cat "$TEST_ROOT/followup.md")" "$(cat "$FAKE_CLAUDE_PROMPT_FILE")"
assert_contains 'the follow-up verdict names the turn 2 result file' "$OUTPUT" "/turns/0002/result.md "

new_block busy
start_label busy block.md
busy_worker="$WORKER"
dispatch send --session "$SESSION" --label busy --task-file "$TEST_ROOT/quick.md"
assert_eq 'send to a running worker is not reached because the CLI refuses it' \
  "11|GLM_NOT_REACHED reason=cli-failed" "$RC|$OUTPUT"
assert_eq 'a refused send leaves the registry turn unchanged' 1 "$(reg_get busy turn)"

dispatch pending --session "$SESSION"
assert_eq 'pending lists running and unacknowledged-terminal workers' \
  $'GLM_PENDING label=busy worker='"$busy_worker"$' state=running status=RUNNING\nGLM_PENDING label=first worker='"$first_worker"' state=terminal-unacked status=DONE' \
  "$OUTPUT"
dispatch ack --session "$SESSION" --label busy
assert_eq 'ack on a running worker is refused with exit 1' \
  "1|GLM_ACK_REFUSED label=busy reason=running" "$RC|$OUTPUT"
dispatch ack --session "$SESSION" --label first
dispatch pending --session "$SESSION"
assert_eq 'pending skips acknowledged terminal workers' \
  "GLM_PENDING label=busy worker=$busy_worker state=running status=RUNNING" "$OUTPUT"

dispatch status --session "$SESSION" --label busy
assert_eq 'status prints the label line and the CLI status output' \
  "0|LABEL=busy|WORKER_ID=$busy_worker|STATUS=RUNNING" \
  "$RC|$(sed -n '1p' <<<"$OUTPUT")|$(sed -n '2p' <<<"$OUTPUT")|$(sed -n '3p' <<<"$OUTPUT")"
dispatch result --session "$SESSION" --label first
assert_eq 'result prints the label line and the result path' \
  "0|LABEL=first|$GLM_AGENT_HOME/workers/$first_worker/turns/0002/result.md" \
  "$RC|$(sed -n '1p' <<<"$OUTPUT")|$(sed -n '2p' <<<"$OUTPUT")"
dispatch result --session "$SESSION" --label busy
assert_eq 'result keeps the CLI exit status when no result exists' "2|LABEL=busy" "$RC|$OUTPUT"

dispatch close --session "$SESSION" --label busy
assert_eq 'close refuses a running worker with exit 1' \
  "1|GLM_CLOSE_REFUSED label=busy reason=running" "$RC|$OUTPUT"
assert_eq 'a refused close leaves the worker open' false \
  "$(kv_file_get "$GLM_AGENT_HOME/workers/$busy_worker/meta" closed)"
dispatch cancel --session "$SESSION" --label busy
assert_contains 'cancel prints the label line and the CLI cancel output' \
  "$OUTPUT" $'LABEL=busy\nWORKER_ID='"$busy_worker"
assert_contains 'cancel stops the running worker' "$OUTPUT" 'CANCEL_RESULT=CANCELLED'
dispatch close --session "$SESSION" --label busy
assert_eq 'close of a stopped worker runs the CLI close' \
  "0|WORKER_ID=$busy_worker|CLOSED=true" "$RC|$(sed -n '1p' <<<"$OUTPUT")|$(sed -n '2p' <<<"$OUTPUT")"
assert_eq 'close marks the worker closed' true \
  "$(kv_file_get "$GLM_AGENT_HOME/workers/$busy_worker/meta" closed)"
dispatch ack --session "$SESSION" --label busy
dispatch pending --session "$SESSION"
assert_eq 'pending reports none when everything is acknowledged' 'GLM_PENDING none' "$OUTPUT"

next_session
dispatch pending --session "$SESSION"
assert_eq 'pending in a session without dispatches reports none' "0|GLM_PENDING none" "$RC|$OUTPUT"

new_block attach
start_label late block.md
late_worker="$WORKER"
dispatch attach --session "$SESSION" --label late --max-wait 2 --poll-seconds 1 --stall-timeout 0
assert_contains 'attach on a running worker honours --max-wait' "$OUTPUT" "GLM_STILL_RUNNING label=late worker=$late_worker "
assert_eq 'attach exits 13 at the max-wait limit' 13 "$RC"
release_block
wait_terminal "$late_worker"
dispatch attach --session "$SESSION" --label late --poll-seconds 1
assert_eq 'attach on a worker that ended earlier prints its verdict' 0 "$RC"
assert_contains 'attach prints a GLM_VERDICT line' "$OUTPUT" "GLM_VERDICT label=late worker=$late_worker status=DONE "
assert_contains 'attach prints the result sections' "$OUTPUT" '--- Summary ---'
assert_eq 'attach leaves the registry acknowledgement alone' false "$(reg_get late acked)"

new_silent_block attach-stall
start_label quiet silent.md
quiet_worker="$WORKER"
dispatch attach --session "$SESSION" --label quiet --poll-seconds 1 --stall-timeout 2 --max-wait 60
assert_eq 'attach applies stall detection' 12 "$RC"
assert_contains 'attach reports the stalled worker' "$OUTPUT" "GLM_STALLED label=quiet worker=$quiet_worker idle_seconds="
release_silent_block
wait_terminal "$quiet_worker"

GIT_PROJECT="$TEST_ROOT/send-git"
make_git_project "$GIT_PROJECT"
next_session
dispatch run --session "$SESSION" --label gitrun --model sonnet --role explorer --cwd "$GIT_PROJECT" \
  --task-file "$TEST_ROOT/create.md" --wait --poll-seconds 1
assert_contains 'the first turn counts the new file' "$OUTPUT" ' files_changed=1 '
dispatch send --session "$SESSION" --label gitrun --task-file "$TEST_ROOT/touch.md" \
  --wait --poll-seconds 1 --allow-path 'docs/*'
assert_contains 'send takes a fresh git snapshot so only the new edit counts' "$OUTPUT" ' files_changed=1 '
assert_contains 'send warns about the explorer edit of this turn only' "$OUTPUT" \
  'GLM_WARN explorer_modified files=tracked.txt'
assert_contains 'send applies allow-path to its own turn' "$OUTPUT" 'GLM_WARN out_of_scope files=tracked.txt'
assert_eq 'send stores its allow-path globs' 'docs/*' \
  "$(cat "$REGISTRY/$SESSION/gitrun.allow")"

use_fake_cli
fake_cli_set quota "$(fake_quota_healthy)"
fake_cli_set start "$(fake_receipt w-1 1 sonnet general-purpose RUNNING)"
fake_worker_meta w-1 general-purpose sonnet "$PROJECT"
next_session
dispatch run --session "$SESSION" --label fk --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$TEST_ROOT/quick.md"
assert_eq 'the fake run registers the label' 0 "$RC"
send_case() {
  dispatch send --session "$SESSION" --label fk --task-file "$TEST_ROOT/followup.md"
}
unreached() {
  assert_eq "send reports reason=$1 and exits 11" "11|GLM_NOT_REACHED reason=$1" "$RC|$OUTPUT"
  assert_eq "send with reason=$1 leaves the registry turn alone" 1 "$(reg_get fk turn)"
}
fake_cli_set send '' 1
send_case
unreached cli-failed
fake_cli_set send "$(fake_receipt w-1 2 sonnet general-purpose RUNNING | sed '/^RESULT=/d')"
send_case
unreached receipt-incomplete
fake_cli_set send "$(fake_receipt w-ghost 2 sonnet general-purpose RUNNING)"
send_case
unreached meta-missing
fake_cli_set send "$(fake_receipt w-1 2 sonnet explorer RUNNING)"
send_case
unreached meta-mismatch
fake_cli_set send "$(fake_receipt w-1 1 sonnet general-purpose RUNNING)"
send_case
unreached meta-mismatch
fake_worker_meta w-2 general-purpose sonnet "$PROJECT"
fake_cli_set send "$(fake_receipt w-2 2 sonnet general-purpose RUNNING)"
send_case
unreached meta-mismatch
fake_cli_set send "$(fake_receipt w-1 2 sonnet general-purpose DONE)"
send_case
unreached not-running
fake_cli_set send "$(fake_receipt w-1 2 sonnet general-purpose RUNNING)"
send_case
assert_eq 'a verified send prints the receipt for the new turn' \
  "0|GLM_RECEIPT label=fk worker=w-1 turn=2 role=general-purpose model=sonnet cwd=$PROJECT scope=personal quota_5h_used=2789 quota_1w_used=37560" \
  "$RC|$OUTPUT"
last_send="$(fake_cli_calls send)"
assert_eq 'send passes --async and the worker id to the CLI' \
  'arg=send arg=--async arg=w-1' \
  "$(sed -n "/^call=$last_send\$/,\$p" "$FAKE_CLI_DIR/send.argv" | sed -n '2,4p' | tr '\n' ' ' | sed 's/ $//')"
assert_eq 'the follow-up brief reaches the CLI send byte for byte' 0 \
  "$(cmp -s "$FAKE_CLI_DIR/send.lastarg" "$TEST_ROOT/followup.md" && printf 0 || printf 1)"
healthy="$(fake_quota_healthy)"
fake_cli_set quota "${healthy/LIMIT_1_REMAINING=32211/LIMIT_1_REMAINING=0}"
calls_before="$(fake_cli_calls send)"
send_case
assert_eq 'send re-applies the quota gate before sending' \
  "10|GLM_BLOCKED row=4 reset_at=2026-10-03T05:37:58Z scope=personal" "$RC|$OUTPUT"
assert_eq 'a blocked send never calls the CLI send' 0 "$(($(fake_cli_calls send) - calls_before))"

finish
