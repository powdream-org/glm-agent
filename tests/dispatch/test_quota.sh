#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROWS_TSV="$DT_DIR/quota-rows.tsv"
FIVE_RESET=2026-10-03T05:37:58Z
WEEK_RESET=2026-10-09T07:29:02Z
GATE_CLI="$FAKE_BIN/fake-cli"
GATE_SMALL=false
GATE_EST=""

quota_ok() {
  printf 'QUOTA_STATUS=OK\nSCOPE=%s\nPLAN_LEVEL=max\nLIMIT_COUNT=2\n' "$1"
  printf 'LIMIT_1_TYPE=CREDIT_LIMIT\nLIMIT_1_WINDOW=5h\nLIMIT_1_TOTAL=35000\n'
  printf 'LIMIT_1_USED=%s\nLIMIT_1_REMAINING=%s\nLIMIT_1_USED_PERCENT=%s\nLIMIT_1_RESET_AT=%s\n' \
    "$2" "$3" "$4" "$5"
  printf 'LIMIT_2_TYPE=CREDIT_LIMIT\nLIMIT_2_WINDOW=1w\nLIMIT_2_TOTAL=155000\n'
  printf 'LIMIT_2_USED=%s\nLIMIT_2_REMAINING=%s\nLIMIT_2_USED_PERCENT=%s\nLIMIT_2_RESET_AT=%s\n' \
    "$6" "$7" "$8" "$9"
  printf 'RESPONSE=/tmp/r.json\nERROR_KIND=\nPROVIDER_CODE=\n'
}

quota_healthy() {
  quota_ok team 2789 32211 7 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET"
}

quota_invalid() {
  printf 'QUOTA_STATUS=INVALID\nSCOPE=personal\nRESPONSE=/tmp/r.json\nERROR_KIND=%s\nPROVIDER_CODE=\n' "$1"
}

GATE_SCRIPT="$TEST_ROOT/gate-probe.sh"
cat >"$GATE_SCRIPT" <<'PROBE'
set -Eeuo pipefail
source "$1/scripts/lib/dispatch-common.sh"
source "$1/scripts/lib/dispatch-quota.sh"
DD_CLI="$2"
DD_SMALL="$3"
DD_EST_CREDITS="$4"
dd_gate_quota
printf 'PASS scope=%s q5=%s q1w=%s\n' "$DD_QUOTA_SCOPE" "$DD_QUOTA_5H_USED" "$DD_QUOTA_1W_USED"
PROBE

gate() {
  capture "$BASH" "$GATE_SCRIPT" "$REPO_DIR" "$GATE_CLI" "$GATE_SMALL" "$GATE_EST"
}

expect_gate() {
  local name="$1" expected="$2"
  gate
  assert_eq "$name" "$expected" "$RC|$OUTPUT"
}

use_fake_cli

fake_cli_set quota '' 2
expect_gate 'quota setup error without a QUOTA_STATUS line blocks row 1' \
  '10|GLM_BLOCKED row=1 reset_at=session scope=unknown'
fake_cli_set quota "$(quota_healthy)" 3
expect_gate 'quota exit status other than 0 or 1 blocks row 1' \
  '10|GLM_BLOCKED row=1 reset_at=session scope=unknown'
fake_cli_set quota 'LIMIT_COUNT=0' 0
expect_gate 'quota output without QUOTA_STATUS blocks row 1' \
  '10|GLM_BLOCKED row=1 reset_at=session scope=unknown'
fake_cli_set quota "$(quota_invalid authentication)" 1
expect_gate 'authentication failure blocks row 1' \
  '10|GLM_BLOCKED row=1 reset_at=session scope=personal'
fake_cli_set quota "$(quota_invalid quota-exhausted)" 1
expect_gate 'quota-exhausted lookup blocks row 2 for the session' \
  '10|GLM_BLOCKED row=2 reset_at=session scope=personal'
for kind in provider-transient model-unavailable provider-error invalid-response; do
  fake_cli_set quota "$(quota_invalid "$kind")" 1
  expect_gate "$kind lookup failure passes fail-open with unknown values" \
    '0|PASS scope=unknown q5=unknown q1w=unknown'
done

fake_cli_set quota "$(quota_ok team 35000 0 100 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
expect_gate 'exhausted 5h window blocks row 4 with its reset time' \
  "10|GLM_BLOCKED row=4 reset_at=$FIVE_RESET scope=team"
fake_cli_set quota "$(quota_ok team 35000 -1 100 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
expect_gate 'negative remaining counts as exhausted' \
  "10|GLM_BLOCKED row=4 reset_at=$FIVE_RESET scope=team"
fake_cli_set quota "$(quota_ok team 35000 0.0 100 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
expect_gate 'decimal zero remaining counts as exhausted' \
  "10|GLM_BLOCKED row=4 reset_at=$FIVE_RESET scope=team"
fake_cli_set quota "$(quota_ok team 35000 0 100 "$FIVE_RESET" 155000 0 100 "$WEEK_RESET")" 0
expect_gate 'two exhausted windows report the latest reset time' \
  "10|GLM_BLOCKED row=4 reset_at=$WEEK_RESET scope=team"
fake_cli_set quota "$(quota_ok team 35000 0 100 '' 37560 117440 24 "$WEEK_RESET")" 0
expect_gate 'exhausted window with an empty reset time blocks for the session' \
  '10|GLM_BLOCKED row=4 reset_at=session scope=team'
fake_cli_set quota "$(quota_healthy; printf 'LIMIT_3_TYPE=CREDIT_LIMIT\nLIMIT_3_WINDOW=u9x2\nLIMIT_3_REMAINING=0\nLIMIT_3_RESET_AT=\n')" 0
expect_gate 'exhausted unrecognised window blocks row 4' \
  '10|GLM_BLOCKED row=4 reset_at=session scope=team'
fake_cli_set quota "$(quota_healthy; printf 'LIMIT_3_TYPE=TIME_LIMIT\nLIMIT_3_WINDOW=\nLIMIT_3_REMAINING=0\nLIMIT_3_RESET_AT=\n')" 0
expect_gate 'exhausted TIME_LIMIT is ignored' \
  '0|PASS scope=team q5=2789 q1w=37560'
fake_cli_set quota "$(quota_ok team 35000 '' 7 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
expect_gate 'empty remaining is never exhausted' \
  '0|PASS scope=team q5=35000 q1w=37560'

fake_cli_set quota "$(quota_healthy)" 0
GATE_EST=20000
expect_gate 'est-credits above half the 5h remaining blocks row 7' \
  "10|GLM_BLOCKED row=7 reset_at=$FIVE_RESET scope=team"
GATE_EST=10000
expect_gate 'est-credits below half of every remaining passes' \
  '0|PASS scope=team q5=2789 q1w=37560'
fake_cli_set quota "$(quota_ok team 2789 32210 7 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
GATE_EST=16105
expect_gate 'remaining equal to twice est-credits passes' \
  '0|PASS scope=team q5=2789 q1w=37560'
fake_cli_set quota "$(quota_ok team 2789 32209 7 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
expect_gate 'remaining one below twice est-credits blocks row 7' \
  "10|GLM_BLOCKED row=7 reset_at=$FIVE_RESET scope=team"
fake_cli_set quota "$(quota_ok team 2789 32211 7 "$FIVE_RESET" 37560 31000 24 "$WEEK_RESET")" 0
GATE_EST=16000
expect_gate 'est-credits checks the 1w window too' \
  "10|GLM_BLOCKED row=7 reset_at=$WEEK_RESET scope=team"
fake_cli_set quota "$(quota_healthy; printf 'LIMIT_3_TYPE=CREDIT_LIMIT\nLIMIT_3_WINDOW=u9x2\nLIMIT_3_REMAINING=1\nLIMIT_3_RESET_AT=\n')" 0
GATE_EST=10000
expect_gate 'est-credits ignores unrecognised windows' \
  '0|PASS scope=team q5=2789 q1w=37560'
GATE_EST=""
fake_cli_set quota "$(quota_ok team 2789 10 7 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
expect_gate 'low remaining without est-credits passes' \
  '0|PASS scope=team q5=2789 q1w=37560'

fake_cli_set quota "$(quota_ok team 31500 3500 90 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
expect_gate '5h usage at 90 percent blocks row 5 without --small' \
  "10|GLM_BLOCKED row=5 reset_at=$FIVE_RESET scope=team"
GATE_SMALL=true
expect_gate '5h usage at 90 percent passes with --small' \
  '0|PASS scope=team q5=31500 q1w=37560'
GATE_SMALL=false
fake_cli_set quota "$(quota_ok team 31000 4000 89 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
expect_gate '5h usage at 89 percent passes' \
  '0|PASS scope=team q5=31000 q1w=37560'
fake_cli_set quota "$(quota_ok team 2789 32211 7 "$FIVE_RESET" 151900 3100 98 "$WEEK_RESET")" 0
expect_gate '1w usage at 98 percent blocks row 5' \
  "10|GLM_BLOCKED row=5 reset_at=$WEEK_RESET scope=team"
fake_cli_set quota "$(quota_ok team 2789 32211 7 "$FIVE_RESET" 150000 5000 97 "$WEEK_RESET")" 0
expect_gate '1w usage at 97 percent passes' \
  '0|PASS scope=team q5=2789 q1w=150000'
fake_cli_set quota "$(quota_ok team 35000 0 100 "$FIVE_RESET" 150000 5000 98 "$WEEK_RESET")" 0
GATE_EST=1000
expect_gate 'row 4 outranks rows 5 and 7' \
  "10|GLM_BLOCKED row=4 reset_at=$FIVE_RESET scope=team"
fake_cli_set quota "$(quota_ok team 31500 3500 90 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
GATE_EST=20000
expect_gate 'row 7 outranks row 5' \
  "10|GLM_BLOCKED row=7 reset_at=$FIVE_RESET scope=team"
GATE_EST=""

fake_cli_set quota "$(quota_ok personal '' 32211 7 "$FIVE_RESET" '' 117440 24 "$WEEK_RESET")" 0
expect_gate 'missing used values are reported as unknown' \
  '0|PASS scope=personal q5=unknown q1w=unknown'
fake_cli_set quota "$(quota_healthy)" 0
calls_before="$(fake_cli_calls quota)"
gate
assert_eq 'a passing gate prints one line and never the raw quota output' \
  1 "$(printf '%s\n' "$OUTPUT" | wc -l | tr -d ' ')"
assert_eq 'gate calls the CLI quota subcommand exactly once' 1 \
  "$(($(fake_cli_calls quota) - calls_before))"

GATE_CLI="$REAL_CLI"
expect_gate 'real CLI quota output parses into scope and used values' \
  '0|PASS scope=personal q5=2789 q1w=37560'
assert_not_contains 'gate output never contains the stored key' \
  "$OUTPUT$STDERR" 'zk-dispatch-test'
export FAKE_CURL_STATUS=401
expect_gate 'real CLI HTTP 401 blocks row 1' \
  '10|GLM_BLOCKED row=1 reset_at=session scope=personal'
export FAKE_CURL_STATUS=200 FAKE_CURL_EXIT=28
expect_gate 'real CLI curl timeout passes fail-open' \
  '0|PASS scope=unknown q5=unknown q1w=unknown'
unset FAKE_CURL_STATUS FAKE_CURL_EXIT
export GLM_AGENT_HOME="$TEST_ROOT/empty-home"
expect_gate 'real CLI without a stored key blocks row 1' \
  '10|GLM_BLOCKED row=1 reset_at=session scope=unknown'
export GLM_AGENT_HOME="$TEST_ROOT/home/.glm"
GATE_CLI="$FAKE_BIN/fake-cli"

probe_row() {
  GATE_SMALL=false
  GATE_EST=""
  case "$1" in
    1)
      fake_cli_set quota "$(quota_invalid authentication)" 1
      ROW_EXPECT='10|GLM_BLOCKED row=1 '
      ;;
    2)
      fake_cli_set quota "$(quota_invalid quota-exhausted)" 1
      ROW_EXPECT='10|GLM_BLOCKED row=2 '
      ;;
    3)
      fake_cli_set quota "$(quota_invalid provider-transient)" 1
      ROW_EXPECT='0|PASS '
      ;;
    4)
      fake_cli_set quota "$(quota_ok team 35000 0 100 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
      ROW_EXPECT='10|GLM_BLOCKED row=4 '
      ;;
    5)
      fake_cli_set quota "$(quota_ok team 31500 3500 90 "$FIVE_RESET" 37560 117440 24 "$WEEK_RESET")" 0
      ROW_EXPECT='10|GLM_BLOCKED row=5 '
      ;;
    7)
      fake_cli_set quota "$(quota_healthy)" 0
      GATE_EST=20000
      ROW_EXPECT='10|GLM_BLOCKED row=7 '
      ;;
    *)
      ROW_EXPECT='no scenario for this row'
      return 1
      ;;
  esac
  gate
  [[ "$RC|$OUTPUT" == "$ROW_EXPECT"* ]]
}

assert_eq 'quota-rows.tsv has exactly nine lines' 9 \
  "$(wc -l <"$ROWS_TSV" | tr -d ' ')"
assert_eq 'quota-rows.tsv covers rows 1 2 3 4 5 7' '1 2 3 4 5 7 ' \
  "$(cut -f1 "$ROWS_TSV" | sort -u | tr '\n' ' ')"
while IFS= read -r row; do
  if probe_row "$row"; then
    pass "core output matches quota-rows.tsv row $row"
  else
    fail "core output matches quota-rows.tsv row $row" \
      "rc|output=[$RC|$OUTPUT] expected prefix [$ROW_EXPECT]"
  fi
done < <(cut -f1 "$ROWS_TSV" | sort -u)

finish
