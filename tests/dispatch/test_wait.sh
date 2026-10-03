#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_brief plain.md $'# Task\nplain work\n'
make_brief block.md $'# Task\nWAIT_FOR_RELEASE\n'
make_brief blocked.md $'# Task\nRETURN_BLOCKED\n'
make_brief long.md $'# Task\nLONG_SECTIONS\n'
make_brief missing.md $'# Task\nMISSING_RESULT\n'
make_brief malformed.md $'# Task\nMALFORMED_RESULT\n'
make_brief quota.md $'# Task\nZAI_ERROR_1113\n'
make_brief fail.md $'# Task\nCLAUDE_FAIL\n'
PLAIN="$TEST_ROOT/plain.md"
BLOCK="$TEST_ROOT/block.md"

run_wait() {
  local label="$1" brief="$2"
  shift 2
  next_session
  dispatch run --session "$SESSION" --label "$label" --cwd "$PROJECT" \
    --task-file "$brief" --wait --poll-seconds 1 "$@"
  WORKER="$(receipt_worker "$OUTPUT")"
}

verdict_of() {
  grep '^GLM_VERDICT' <<<"$OUTPUT" || true
}

use_real_cli

run_wait immediate "$PLAIN"
result_path="$GLM_AGENT_HOME/workers/$WORKER/turns/0001/result.md"
assert_eq 'a worker that ends right after start yields a DONE verdict and exit 0' \
  "0|GLM_VERDICT label=immediate worker=$WORKER status=DONE class=- result=$result_path files_changed=na quota_1w_delta=0 fallback=false" \
  "$RC|$(verdict_of)"
assert_eq 'run --wait prints the receipt first and the result sections last' \
  "GLM_RECEIPT|GLM_VERDICT|--- Summary ---|--- Remaining Issues ---" \
  "$(grep -E '^(GLM_RECEIPT|GLM_VERDICT|--- Summary ---|--- Remaining Issues ---)' <<<"$OUTPUT" | sed -E 's/^(GLM_[A-Z]+|--- [A-Za-z ]+ ---).*/\1/' | tr '\n' '|' | sed 's/|$//')"
assert_eq 'the Summary section follows its header' \
  $'--- Summary ---\nCompleted by fake worker\n' \
  "$(sed -n '/^--- Summary ---$/,/^--- Remaining Issues ---$/p' <<<"$OUTPUT" | sed '$d')"$'\n'
assert_eq 'the Remaining Issues section ends the output' \
  $'--- Remaining Issues ---\nNone\n' "$(sed -n '/^--- Remaining Issues ---$/,$p' <<<"$OUTPUT")"$'\n'

use_spy_cli
export SPY_SETTLE_AFTER_START=1
run_wait settled "$PLAIN"
assert_eq 'a worker that already ended before the first wait is judged DONE' \
  "0|1|DONE" \
  "$RC|$(grep -c '^TERMINAL$' "$SPY_LOG")|$(sed -n 's/.* status=\([A-Z]*\) .*/\1/p' <<<"$(verdict_of)")"
assert_eq 'the first wait already returned TERMINAL' TERMINAL "$(sed -n '1p' "$SPY_LOG")"
export SPY_SETTLE_AFTER_START=0

use_spy_cli
new_block race3
next_session
race_out="$TEST_ROOT/race3.out"
"$BASH" "$DISPATCH" run --session "$SESSION" --label during --cwd "$PROJECT" \
  --task-file "$BLOCK" --wait --poll-seconds 1 >"$race_out" 2>&1 &
race_pid=$!
wait_for_file "$FAKE_CLAUDE_BLOCK_STARTED"
wait_for_text "$SPY_LOG" TIMEOUT
release_block
race_rc=0
wait "$race_pid" || race_rc=$?
assert_eq 'a worker that ends during the wait is judged DONE after TIMEOUT polls' \
  "0|DONE" \
  "$race_rc|$(sed -n 's/^GLM_VERDICT .* status=\([A-Z]*\) .*/\1/p' "$race_out")"
assert_eq 'the wait loop saw TIMEOUT before TERMINAL' TERMINAL "$(tail -n 1 "$SPY_LOG")"
assert_contains 'the wait loop saw TIMEOUT before TERMINAL' "$(cat "$SPY_LOG")" TIMEOUT

use_real_cli
new_block race4
run_wait toolong "$BLOCK" --max-wait 2 --stall-timeout 0
waited="$(sed -n 's/^GLM_STILL_RUNNING label=toolong worker=[^ ]* waited_seconds=\([0-9]*\)$/\1/p' <<<"$OUTPUT")"
assert_eq 'exceeding --max-wait prints GLM_STILL_RUNNING and exits 13' 13 "$RC"
if [[ -n "$waited" ]] && ((waited >= 2)); then
  pass 'GLM_STILL_RUNNING reports the waited seconds'
else
  fail 'GLM_STILL_RUNNING reports the waited seconds' "output=[$OUTPUT]"
fi
assert_not_contains 'a timed-out wait prints no verdict' "$OUTPUT" GLM_VERDICT
assert_contains 'the worker keeps running after the max-wait exit' \
  "$("$REAL_CLI" status "$WORKER")" 'STATUS=RUNNING'
release_block
wait_terminal "$WORKER"

run_wait blocked "$TEST_ROOT/blocked.md"
assert_eq 'a BLOCKED worker yields status=BLOCKED and exit 1' \
  "1|BLOCKED" "$RC|$(sed -n 's/^GLM_VERDICT .* status=\([A-Z]*\) .*/\1/p' <<<"$OUTPUT")"
assert_contains 'the Remaining Issues section quotes NEEDS-MAIN lines' "$OUTPUT" 'NEEDS-MAIN: decide'
run_wait invalid "$TEST_ROOT/fail.md"
assert_eq 'an invocation failure yields status=INVALID and exit 1' \
  "1|INVALID" "$RC|$(sed -n 's/^GLM_VERDICT .* status=\([A-Z]*\) .*/\1/p' <<<"$OUTPUT")"
run_wait quota "$TEST_ROOT/quota.md"
assert_contains 'a quota-exhausted turn reports class and fallback' \
  "$(verdict_of)" ' class=quota-exhausted '
assert_contains 'a quota-exhausted turn recommends fallback' "$(verdict_of)" ' fallback=true'
run_wait malformed "$TEST_ROOT/malformed.md"
assert_contains 'a malformed result is classified worker-protocol' \
  "$(verdict_of)" ' class=worker-protocol '
run_wait missing "$TEST_ROOT/missing.md"
assert_eq 'a missing result file omits both section headers' 0 \
  "$(grep -c '^--- ' <<<"$OUTPUT" || true)"

run_wait long "$TEST_ROOT/long.md"
summary_lines="$(sed -n '/^--- Summary ---$/,/^--- Remaining Issues ---$/p' <<<"$OUTPUT" | sed '1d;$d')"
assert_eq 'a long Summary is cut at 20 lines plus a truncation line' 21 \
  "$(printf '%s\n' "$summary_lines" | wc -l | tr -d ' ')"
assert_eq 'the truncation line closes the cut Summary' '... (truncated)' \
  "$(printf '%s\n' "$summary_lines" | tail -n 1)"
assert_eq 'the 20th Summary line is kept' 'summary line 20' \
  "$(printf '%s\n' "$summary_lines" | sed -n '20p')"
issue_lines="$(sed -n '/^--- Remaining Issues ---$/,$p' <<<"$OUTPUT" | sed '1d')"
assert_eq 'a long Remaining Issues section is cut at 20 lines plus a truncation line' 21 \
  "$(printf '%s\n' "$issue_lines" | wc -l | tr -d ' ')"

use_fake_cli
FAKE_RESULT="$TEST_ROOT/fake-result.md"
printf '# Summary\nfake summary\n\n# Remaining Issues\nfake issue\n\nSTATUS: DONE\n' >"$FAKE_RESULT"
fake_worker_meta w-fake general-purpose sonnet "$PROJECT"
fake_status() {
  printf 'WORKER_ID=w-fake\nSTATUS=%s\nTURN=1\nMODEL=sonnet\nROLE=general-purpose\nCWD=%s\nCLOSED=false\n' "$1" "$PROJECT"
  printf 'RESULT=%s\nERROR_KIND=%s\nPROVIDER_CODE=\nFALLBACK_RECOMMENDED=%s\nACTIVE_MODE=\nACTIVE_TURN=\n' "$2" "$3" "$4"
}
prepare_fake() {
  use_fake_cli
  fake_cli_set quota "$(fake_quota_healthy)"
  fake_cli_set start "$(fake_receipt w-fake 1 sonnet general-purpose RUNNING)"
  fake_cli_set wait $'WORKER_ID=w-fake\nWAIT_RESULT=TERMINAL'
}

prepare_fake
fake_cli_set status "$(fake_status DONE "$FAKE_RESULT" '' false)"
healthy="$(fake_quota_healthy)"
fake_cli_seq quota 2 "${healthy/LIMIT_2_USED=37560/LIMIT_2_USED=37660}"
run_wait delta "$PLAIN"
assert_contains 'a rise in 1w usage is reported with a plus sign' "$(verdict_of)" ' quota_1w_delta=+100 '
prepare_fake
fake_cli_set status "$(fake_status DONE "$FAKE_RESULT" '' false)"
fake_cli_seq quota 2 "${healthy/LIMIT_2_USED=37560/LIMIT_2_USED=37555}"
run_wait delta-down "$PLAIN"
assert_contains 'a fall in 1w usage is reported with a minus sign' "$(verdict_of)" ' quota_1w_delta=-5 '
prepare_fake
fake_cli_set status "$(fake_status DONE "$FAKE_RESULT" '' false)"
fake_cli_seq quota 2 $'QUOTA_STATUS=INVALID\nSCOPE=personal\nERROR_KIND=provider-transient'
run_wait delta-unknown "$PLAIN"
assert_contains 'a failed second quota read reports unknown' "$(verdict_of)" ' quota_1w_delta=unknown '
prepare_fake
fake_cli_set status "$(fake_status INVALID '' quota-exhausted true)" 
run_wait fallback "$PLAIN"
assert_eq 'a quota-exhausted status maps to class, no result, and fallback' \
  "1|GLM_VERDICT label=fallback worker=w-fake status=INVALID class=quota-exhausted result=- files_changed=na quota_1w_delta=0 fallback=true" \
  "$RC|$(verdict_of)"
assert_not_contains 'a verdict without a result file prints no sections' "$OUTPUT" '--- Summary ---'

prepare_fake
fake_cli_set status "$(fake_status DONE "$FAKE_RESULT" '' false)"
fake_cli_seq wait 1 $'WORKER_ID=w-fake\nWAIT_RESULT=TIMEOUT'
fake_cli_seq wait 2 $'WORKER_ID=w-fake\nWAIT_RESULT=TERMINAL'
next_session
dispatch run --session "$SESSION" --label poll --cwd "$PROJECT" --task-file "$PLAIN" \
  --wait --max-wait 3 --poll-seconds 5
assert_eq 'the wait timeout is capped by the remaining max-wait' \
  "wait --timeout 3 w-fake" \
  "$(sed -n '1,/^call=2$/p' "$FAKE_CLI_DIR/wait.argv" | sed -n 's/^arg=//p' | head -n 4 | tr '\n' ' ' | sed 's/ $//')"
assert_eq 'two wait calls were needed' 2 "$(fake_cli_calls wait)"

prepare_fake
next_session
dispatch run --session "$SESSION" --label nowait --cwd "$PROJECT" --task-file "$PLAIN"
assert_eq 'run without --wait never calls wait or status' "0|0" \
  "$(fake_cli_calls wait)|$(fake_cli_calls status)"

finish
