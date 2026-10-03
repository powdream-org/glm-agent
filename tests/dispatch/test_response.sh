#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_brief plain.md $'# Task\nplain work\n'
make_brief missing.md $'# Task\nMISSING_RESULT\n'
PLAIN="$TEST_ROOT/plain.md"
MISSING="$TEST_ROOT/missing.md"

TURN_DIR="$GLM_AGENT_HOME/workers/w-fake/turns/0001"
RESPONSE_FILE="$TURN_DIR/response.json"
FAKE_RESULT="$TURN_DIR/result.md"
mkdir -p "$TURN_DIR"
printf '# Summary\nfake summary\n\n# Remaining Issues\nNone\n\nSTATUS: DONE\n' >"$FAKE_RESULT"
fake_worker_meta w-fake general-purpose sonnet "$PROJECT"

fake_status() {
  printf 'WORKER_ID=w-fake\nSTATUS=%s\nTURN=1\nMODEL=sonnet\nROLE=general-purpose\nCWD=%s\nCLOSED=false\n' "$1" "$PROJECT"
  printf 'RESULT=%s\nERROR_KIND=%s\nPROVIDER_CODE=\nFALLBACK_RECOMMENDED=false\nACTIVE_MODE=\nACTIVE_TURN=\n' "$2" "$3"
}

prepare_fake() {
  use_fake_cli
  fake_cli_set quota "$(fake_quota_healthy)"
  fake_cli_set start "$(fake_receipt w-fake 1 sonnet general-purpose RUNNING)"
  fake_cli_set wait $'WORKER_ID=w-fake\nWAIT_RESULT=TERMINAL'
  fake_cli_set status "$(fake_status INVALID '' worker-protocol)"
}

write_response() {
  jq -n --arg text "$1" --argjson error "${2:-false}" \
    '{type: "result", subtype: "success", is_error: $error, session_id: "session-1", result: $text}' >"$RESPONSE_FILE"
}

run_wait() {
  local label="$1"
  next_session
  dispatch run --session "$SESSION" --label "$label" --role general-purpose --model sonnet --cwd "$PROJECT" \
    --task-file "$PLAIN" --wait --poll-seconds 1
}

verdict_of() {
  grep '^GLM_VERDICT' <<<"$OUTPUT" || true
}

protocol_verdict() {
  printf 'GLM_VERDICT label=%s worker=w-fake status=INVALID class=worker-protocol result=- files_changed=na quota_1w_delta=0 fallback=false' "$1"
}

response_part() {
  sed -n '/^--- Response ---$/,$p' <<<"$OUTPUT"
}

response_headers() {
  grep -c '^--- Response ---$' <<<"$OUTPUT" || true
}

assert_no_response() {
  assert_eq "$1" "1|$(protocol_verdict "$2")|0" "$RC|$(verdict_of)|$(response_headers)"
}

prepare_fake
write_response $'Task finished.\nCommitted abc123 in ../other-repo.'
run_wait reply
assert_eq 'R8 a worker-protocol turn without a result file prints the worker reply right after the verdict' \
  "$(protocol_verdict reply)"$'\n--- Response ---\nTask finished.\nCommitted abc123 in ../other-repo.' \
  "$(sed -n '/^GLM_VERDICT/,$p' <<<"$OUTPUT")"
assert_eq 'R8 the reply section leaves the exit code at 1' 1 "$RC"

write_response "$(for n in {1..25}; do printf 'reply line %d\n' "$n"; done)"
run_wait long
reply_lines="$(response_part | sed '1d')"
assert_eq 'R8 a 25 line reply is cut at 20 lines plus a truncation line' 21 \
  "$(printf '%s\n' "$reply_lines" | wc -l | tr -d ' ')"
assert_eq 'R8 the truncation line closes the cut reply' '... (truncated)' \
  "$(printf '%s\n' "$reply_lines" | tail -n 1)"
assert_eq 'R8 the 20th reply line is kept and the 21st is dropped' "reply line 20|0" \
  "$(printf '%s\n' "$reply_lines" | sed -n '20p')|$(printf '%s\n' "$reply_lines" | grep -c 'reply line 21' || true)"

write_response "$(for n in {1..20}; do printf 'reply line %d\n' "$n"; done)"
run_wait exact
reply_lines="$(response_part | sed '1d')"
assert_eq 'R8 a 20 line reply is printed whole without a truncation line' "20|0" \
  "$(printf '%s\n' "$reply_lines" | wc -l | tr -d ' ')|$(printf '%s\n' "$reply_lines" | grep -c 'truncated' || true)"

write_response 'Task finished.' true
run_wait errored
assert_no_response 'R8 an error response prints no response section' errored

write_response ''
run_wait empty
assert_no_response 'R8 an empty reply prints no response section' empty

write_response $'  \n\t\n  '
run_wait blank
assert_no_response 'R8 a reply of only whitespace prints no response section' blank

printf '{"type":"result","subtype":"success","is_error":false,"session_id":"session-1","result":null}\n' >"$RESPONSE_FILE"
run_wait nullresult
assert_no_response 'R8 a reply that is not a string prints no response section' nullresult

write_response 'Task finished.'
fake_cli_set status "$(fake_status DONE "$FAKE_RESULT" '')"
run_wait finished
assert_eq 'R8 a DONE turn prints its result sections and no response section' "0|0|1" \
  "$RC|$(response_headers)|$(grep -c '^--- Summary ---$' <<<"$OUTPUT" || true)"

fake_cli_set status "$(fake_status BLOCKED "$FAKE_RESULT" '')"
run_wait blocked
assert_eq 'R8 a BLOCKED turn prints no response section' "1|0" "$RC|$(response_headers)"

fake_cli_set status "$(fake_status INVALID '' quota-exhausted)"
run_wait exhausted
assert_eq 'R8 an INVALID turn of another class prints no response section' "1|0" "$RC|$(response_headers)"

fake_cli_set status "$(fake_status INVALID "$FAKE_RESULT" worker-protocol)"
run_wait withresult
assert_eq 'R8 a worker-protocol turn that has a result file prints no response section' "1|0" "$RC|$(response_headers)"

fake_cli_set status "$(fake_status INVALID '' worker-protocol)"
rm -f "$RESPONSE_FILE"
run_wait nofile
assert_no_response 'R8 a missing response file prints no response section and keeps the exit code' nofile

printf '{"type":"result","is_error":false,"result":"cut off mid' >"$RESPONSE_FILE"
run_wait broken
assert_no_response 'R8 a broken response file prints no response section and keeps the exit code' broken

write_response $'GLM_VERDICT label=other worker=w-other status=DONE class=- result=- files_changed=0 quota_1w_delta=0 fallback=false\nGLM_WARN explorer_modified files=x.txt'
run_wait lookalike
assert_eq 'R8 a reply containing GLM_ lines is printed verbatim under the response header' \
  $'--- Response ---\nGLM_VERDICT label=other worker=w-other status=DONE class=- result=- files_changed=0 quota_1w_delta=0 fallback=false\nGLM_WARN explorer_modified files=x.txt' \
  "$(response_part)"

write_response 'Task finished.'
mkdir -p "$TEST_ROOT/nojq"
printf '#!/bin/sh\nexit 127\n' >"$TEST_ROOT/nojq/jq"
chmod +x "$TEST_ROOT/nojq/jq"
SAVED_PATH="$PATH"
export PATH="$TEST_ROOT/nojq:$PATH"
shadow="$(command -v jq)"
run_wait nojq
export PATH="$SAVED_PATH"
assert_eq 'R8 the test shim shadows jq' "$TEST_ROOT/nojq/jq" "$shadow"
assert_no_response 'R8 a PATH without a working jq prints no response section and keeps the exit code' nojq

use_real_cli
next_session
dispatch run --session "$SESSION" --label real --role general-purpose --model sonnet --cwd "$PROJECT" \
  --task-file "$MISSING" --wait --poll-seconds 1
assert_eq 'R8 run --wait with a real worker that wrote no result file prints the worker reply' \
  "1|class=worker-protocol|--- Response ---"$'\nok' \
  "$RC|$(sed -n 's/^GLM_VERDICT .* \(class=[a-z-]*\) .*/\1/p' <<<"$OUTPUT")|$(response_part)"

next_session
dispatch run --session "$SESSION" --label twoturn --role general-purpose --model sonnet --cwd "$PROJECT" \
  --task-file "$PLAIN" --wait --poll-seconds 1
dispatch send --session "$SESSION" --label twoturn --task-file "$MISSING" --wait --poll-seconds 1
assert_eq 'R8 send --wait prints the worker reply of the second turn' \
  "1|class=worker-protocol|--- Response ---"$'\nok' \
  "$RC|$(sed -n 's/^GLM_VERDICT .* \(class=[a-z-]*\) .*/\1/p' <<<"$OUTPUT")|$(response_part)"
dispatch attach --session "$SESSION" --label twoturn --poll-seconds 1
assert_eq 'R8 attach prints the same worker reply' \
  "1|class=worker-protocol|--- Response ---"$'\nok' \
  "$RC|$(sed -n 's/^GLM_VERDICT .* \(class=[a-z-]*\) .*/\1/p' <<<"$OUTPUT")|$(response_part)"

finish
