#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_brief brief.md $'# Task\nline two\n\n'
REGISTRY="$GLM_AGENT_HOME/dispatch"

next_session
dispatch run --session "$SESSION" --label first --role explorer --model haiku \
  --cwd "$PROJECT" --task-file "$BRIEF"
worker="$(receipt_worker "$OUTPUT")"
assert_eq 'run prints one GLM_RECEIPT line with the request and quota values' \
  "0|GLM_RECEIPT label=first worker=$worker turn=1 role=explorer model=haiku cwd=$PROJECT scope=personal quota_5h_used=2789 quota_1w_used=37560" \
  "$RC|$OUTPUT"
wait_terminal "$worker"
meta="$GLM_AGENT_HOME/workers/$worker/meta"
assert_file 'receipt worker has a meta file' "$meta"
assert_eq 'worker meta role matches the request' explorer "$(kv_file_get "$meta" role)"
assert_eq 'worker meta model matches the request' haiku "$(kv_file_get "$meta" model)"
assert_eq 'worker meta cwd matches the request' "$PROJECT" "$(kv_file_get "$meta" cwd)"
assert_eq 'claude receives the brief text' "$(cat "$BRIEF")" "$(cat "$FAKE_CLAUDE_PROMPT_FILE")"

registry_file="$REGISTRY/$SESSION/first.env"
assert_file 'run writes the registry file' "$registry_file"
assert_eq 'registry directory mode is 700' 700 "$(file_mode "$REGISTRY/$SESSION")"
assert_eq 'registry file mode is 600' 600 "$(file_mode "$registry_file")"
assert_eq 'registry records the label' first "$(kv_file_get "$registry_file" label)"
assert_eq 'registry records the worker id' "$worker" "$(kv_file_get "$registry_file" worker_id)"
assert_eq 'registry records the role' explorer "$(kv_file_get "$registry_file" role)"
assert_eq 'registry records the model' haiku "$(kv_file_get "$registry_file" model)"
assert_eq 'registry records the cwd' "$PROJECT" "$(kv_file_get "$registry_file" cwd)"
assert_eq 'registry records the task file' "$BRIEF" "$(kv_file_get "$registry_file" task_file)"
started_at="$(kv_file_get "$registry_file" started_at)"
if [[ "$started_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  pass 'registry started_at is a UTC timestamp'
else
  fail 'registry started_at is a UTC timestamp' "got [$started_at]"
fi
assert_eq 'registry records the scope' personal "$(kv_file_get "$registry_file" scope)"
assert_eq 'registry records quota_5h_used' 2789 "$(kv_file_get "$registry_file" quota_5h_used)"
assert_eq 'registry records quota_1w_used' 37560 "$(kv_file_get "$registry_file" quota_1w_used)"
assert_eq 'registry records turn 1' 1 "$(kv_file_get "$registry_file" turn)"
assert_eq 'registry starts unacknowledged' false "$(kv_file_get "$registry_file" acked)"
assert_eq 'registry holds one key per line without blank lines' 0 \
  "$(grep -vc '^[a-z_0-9]*=' "$registry_file" || true)"

before="$(count_entries "$GLM_AGENT_HOME/workers")"
before_content="$(cat "$registry_file")"
dispatch run --session "$SESSION" --label first --role general-purpose --model sonnet --task-file "$BRIEF" --cwd "$PROJECT"
assert_eq 'a duplicate label in the same session exits 2 with one stderr line' \
  "2||glm-dispatch: label already exists" "$RC|$OUTPUT|$STDERR"
assert_eq 'a duplicate label starts no worker' "$before" \
  "$(count_entries "$GLM_AGENT_HOME/workers")"
assert_eq 'a duplicate label leaves the registry untouched' "$before_content" "$(cat "$registry_file")"
next_session
dispatch run --session "$SESSION" --label first --role general-purpose --model sonnet --task-file "$BRIEF" --cwd "$PROJECT"
assert_eq 'the same label in another session is allowed' 0 "$RC"
wait_terminal "$(receipt_worker "$OUTPUT")"

ln -s "$PROJECT" "$TEST_ROOT/project-link"
next_session
dispatch run --session "$SESSION" --label linked --role general-purpose --model sonnet --cwd "$TEST_ROOT/project-link" --task-file "$BRIEF"
assert_contains 'a symlinked cwd is reported as its real path' "$OUTPUT" " cwd=$PROJECT "
wait_terminal "$(receipt_worker "$OUTPUT")"
dispatch run --session "$SESSION" --label scoped --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" \
  --allow-path 'src/*' --allow-path 'docs/*'
assert_eq 'run accepts repeated --allow-path options' 0 "$RC"
wait_terminal "$(receipt_worker "$OUTPUT")"

mkdir -p "$TEST_ROOT/link-a" "$TEST_ROOT/link-b"
ln -s "$DISPATCH" "$TEST_ROOT/link-a/glm-dispatch"
ln -s "$TEST_ROOT/link-a/glm-dispatch" "$TEST_ROOT/link-b/chained"
ln -s ../link-a/glm-dispatch "$TEST_ROOT/link-b/relative"
for entry in chained relative; do
  next_session
  capture "$BASH" "$TEST_ROOT/link-b/$entry" run --session "$SESSION" --label via-link --role general-purpose --model sonnet \
    --cwd "$PROJECT" --task-file "$BRIEF"
  assert_contains "the $entry symlink finds the glm-agent CLI" "$OUTPUT" 'GLM_RECEIPT label=via-link'
  wait_terminal "$(receipt_worker "$OUTPUT")"
done

use_fake_cli
fake_cli_set quota "$(fake_quota_healthy)"
not_reached() {
  local label="$1" reason="$2"
  assert_eq "run reports reason=$reason and exits 11" \
    "11|GLM_NOT_REACHED reason=$reason" "$RC|$OUTPUT"
  assert_no_file "run writes no registry entry for reason=$reason" \
    "$REGISTRY/$SESSION/$label.env"
}

next_session
fake_cli_set start '' 1
dispatch run --session "$SESSION" --label a --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF"
not_reached a cli-failed

fake_cli_set start "$(fake_receipt w-incomplete 1 sonnet general-purpose RUNNING | sed '/^PROVIDER_CODE=/d')" 0
dispatch run --session "$SESSION" --label b --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF"
not_reached b receipt-incomplete

fake_cli_set start "$(fake_receipt ghost 1 sonnet general-purpose RUNNING)" 0
dispatch run --session "$SESSION" --label c --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF"
not_reached c meta-missing

fake_worker_meta w-role general-purpose sonnet "$PROJECT"
fake_cli_set start "$(fake_receipt w-role 1 sonnet explorer RUNNING)" 0
dispatch run --session "$SESSION" --label d --model sonnet --role explorer --cwd "$PROJECT" --task-file "$BRIEF"
not_reached d meta-mismatch

fake_worker_meta w-model explorer haiku "$PROJECT"
fake_cli_set start "$(fake_receipt w-model 1 sonnet explorer RUNNING)" 0
dispatch run --session "$SESSION" --label e --model sonnet --role explorer --cwd "$PROJECT" --task-file "$BRIEF"
not_reached e meta-mismatch

fake_worker_meta w-cwd explorer sonnet "$TEST_ROOT"
fake_cli_set start "$(fake_receipt w-cwd 1 sonnet explorer RUNNING)" 0
dispatch run --session "$SESSION" --label f --model sonnet --role explorer --cwd "$PROJECT" --task-file "$BRIEF"
not_reached f meta-mismatch

fake_worker_meta w-done explorer sonnet "$PROJECT"
fake_cli_set start "$(fake_receipt w-done 1 sonnet explorer DONE)" 0
dispatch run --session "$SESSION" --label g --model sonnet --role explorer --cwd "$PROJECT" --task-file "$BRIEF"
not_reached g not-running

fake_worker_meta w-fast explorer sonnet "$PROJECT" DONE
fake_cli_set start "$(fake_receipt w-fast 1 sonnet explorer RUNNING)" 0
dispatch run --session "$SESSION" --label h --role explorer --model sonnet \
  --cwd "$PROJECT" --task-file "$BRIEF"
assert_eq 'a meta status of DONE does not stop a RUNNING receipt' \
  "0|GLM_RECEIPT label=h worker=w-fast turn=1 role=explorer model=sonnet cwd=$PROJECT scope=personal quota_5h_used=2789 quota_1w_used=37560" \
  "$RC|$OUTPUT"
assert_file 'the fast worker is registered' "$REGISTRY/$SESSION/h.env"
assert_eq 'the brief reaches the CLI start byte for byte' 0 \
  "$(cmp -s "$FAKE_CLI_DIR/start.lastarg" "$BRIEF" && printf 0 || printf 1)"
assert_contains 'run starts the worker asynchronously with role, model, and cwd' \
  "$(tr '\n' ' ' <"$FAKE_CLI_DIR/start.argv")" \
  "arg=start arg=--async arg=--role arg=explorer arg=--model arg=sonnet arg=--cwd arg=$PROJECT"

use_fake_cli
healthy_quota="$(fake_quota_healthy)"
fake_cli_set quota "${healthy_quota/LIMIT_1_REMAINING=32211/LIMIT_1_REMAINING=0}"
fake_cli_set start "$(fake_receipt w-never 1 sonnet explorer RUNNING)" 0
next_session
dispatch run --session "$SESSION" --label blocked --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF"
assert_eq 'an exhausted window blocks run with row 4 and exit 10' \
  '10|GLM_BLOCKED row=4 reset_at=2026-10-03T05:37:58Z scope=personal' "$RC|$OUTPUT"
assert_eq 'a blocked run never calls start' 0 "$(fake_cli_calls start)"
assert_no_file 'a blocked run writes no registry entry' "$REGISTRY/$SESSION/blocked.env"
fake_cli_set quota "$(fake_quota_healthy)"
dispatch run --session "$SESSION" --label estimate --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --est-credits 99999
assert_contains 'run applies --est-credits to the gate' "$OUTPUT" 'GLM_BLOCKED row=7 '

finish
