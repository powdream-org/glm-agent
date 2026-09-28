#!/usr/bin/env bash
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"
SCRIPT="$REPO_DIR/glm-agent"
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
TEST_ROOT="$(mktemp -d "$TEMP_BASE/glm-agent-test.XXXXXX")"
TEST_HOME="$TEST_ROOT/home"
PROJECT="$TEST_ROOT/project"
OTHER_PROJECT="$TEST_ROOT/other-project"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_LOG="$TEST_ROOT/claude.log"
TEST_SYSTEM_PROMPT="$TEST_ROOT/system-prompt.md"
TEST_ROLE_PROMPTS_DIR="$TEST_ROOT/prompts"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_HOME" "$PROJECT" "$OTHER_PROJECT" "$FAKE_BIN" \
  "$TEST_ROLE_PROMPTS_DIR"
PROJECT="$(cd "$PROJECT" && pwd -P)"
OTHER_PROJECT="$(cd "$OTHER_PROJECT" && pwd -P)"

cat >"$FAKE_BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail

prompt="${*: -1}"
resume_id=""
model=""
append_prompt=""
permission_bypass="no"

while (($#)); do
  case "$1" in
    --resume)
      resume_id="$2"
      shift 2
      ;;
    --model)
      model="$2"
      shift 2
      ;;
    --append-system-prompt)
      append_prompt="$2"
      shift 2
      ;;
    --dangerously-skip-permissions)
      permission_bypass="yes"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

{
  printf '%s\n' '--- invocation ---'
  printf 'cwd=%s\n' "$PWD"
  printf 'model=%s\n' "$model"
  printf 'resume=%s\n' "$resume_id"
  printf 'result_file=%s\n' "${GLM_RESULT_FILE:-}"
  printf 'base_url=%s\n' "${ANTHROPIC_BASE_URL:-}"
  printf 'auth_token_set=%s\n' "$([[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]] && printf yes || printf no)"
  printf 'haiku=%s\n' "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"
  printf 'sonnet=%s\n' "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}"
  printf 'opus=%s\n' "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}"
  printf 'compact=%s\n' "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
  printf 'nonessential=%s\n' "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}"
  printf 'timeout=%s\n' "${API_TIMEOUT_MS:-}"
  printf 'claudecode=%s\n' "${CLAUDECODE-unset}"
  printf 'permission_bypass=%s\n' "$permission_bypass"
  if [[ "$append_prompt" == *'Starting a background process is not completion.'* ]] &&
     [[ "$append_prompt" == *'Read the result file back.'* ]]; then
    printf '%s\n' 'contract=present'
  else
    printf '%s\n' 'contract=missing'
  fi
  if [[ -n "${GLM_RESULT_FILE:-}" && "$append_prompt" == *"${GLM_RESULT_FILE}"* ]]; then
    printf '%s\n' 'result_path_in_prompt=yes'
  else
    printf '%s\n' 'result_path_in_prompt=no'
  fi
  case "$append_prompt" in
    *'TEST_PROMPT_REVISION=one'*) printf '%s\n' 'prompt_revision=one' ;;
    *'TEST_PROMPT_REVISION=two'*) printf '%s\n' 'prompt_revision=two' ;;
    *) printf '%s\n' 'prompt_revision=unknown' ;;
  esac
  case "$append_prompt" in
    *'ROLE=explorer'*) printf '%s\n' 'role_prompt=explorer' ;;
    *'ROLE=general-purpose'*) printf '%s\n' 'role_prompt=general-purpose' ;;
    *) printf '%s\n' 'role_prompt=missing' ;;
  esac
  case "$append_prompt" in
    *'ROLE_PROMPT_REVISION=two'*) printf '%s\n' 'role_prompt_revision=two' ;;
    *) printf '%s\n' 'role_prompt_revision=one' ;;
  esac
} >>"$FAKE_CLAUDE_LOG"

if [[ -z "${GLM_RESULT_FILE:-}" ]]; then
  printf '%s\n' 'RUN_OK'
  exit 0
fi

if [[ "$prompt" == *CLAUDE_FAIL* ]]; then
  printf '%s\n' 'simulated claude failure' >&2
  exit 17
fi

case "$prompt" in
  *MISSING_RESULT*)
    ;;
  *MALFORMED_RESULT*)
    printf '# Summary\nMalformed result\n\nSTATUS: MAYBE\n' >"$GLM_RESULT_FILE"
    ;;
  *RETURN_BLOCKED*)
    printf '# Summary\nBlocked as requested\n\nSTATUS: BLOCKED\n' >"$GLM_RESULT_FILE"
    ;;
  *)
    printf '# Summary\nCompleted by fake worker\n\nSTATUS: DONE\n' >"$GLM_RESULT_FILE"
    ;;
esac

if [[ "$prompt" == *BAD_JSON* ]]; then
  printf '%s\n' 'not-json'
  exit 0
fi

session_id="${resume_id:-session-1}"
if [[ "$prompt" == *WRONG_SESSION* ]]; then
  session_id="different-session"
fi

printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","result":"ok"}\n' "$session_id"
FAKE
chmod +x "$FAKE_BIN/claude"

export PATH="$FAKE_BIN:/opt/homebrew/bin:/usr/bin:/bin"
export HOME="$TEST_HOME"
export GLM_AGENT_HOME="$TEST_HOME/.glm"
export FAKE_CLAUDE_LOG="$FAKE_LOG"
export CLAUDECODE=1
export GLM_SYSTEM_PROMPT_FILE="$TEST_SYSTEM_PROMPT"
export GLM_ROLE_PROMPTS_DIR="$TEST_ROLE_PROMPTS_DIR"

write_test_system_prompt() {
  local revision="$1"
  cat >"$TEST_SYSTEM_PROMPT" <<EOF
Starting a background process is not completion.
Read the result file back.
TEST_PROMPT_REVISION=$revision
EOF
}

write_test_system_prompt one

write_test_role_prompts() {
  local revision="$1"
  printf 'ROLE=explorer\nROLE_PROMPT_REVISION=%s\n' "$revision" \
    >"$TEST_ROLE_PROMPTS_DIR/explorer.md"
  printf 'ROLE=general-purpose\nROLE_PROMPT_REVISION=%s\n' "$revision" \
    >"$TEST_ROLE_PROMPTS_DIR/general-purpose.md"
}

write_test_role_prompts one

failures=0
tests=0

pass() {
  tests=$((tests + 1))
  printf 'ok %d - %s\n' "$tests" "$1"
}

fail() {
  tests=$((tests + 1))
  failures=$((failures + 1))
  printf 'not ok %d - %s\n' "$tests" "$1"
  printf '  %s\n' "$2"
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "expected [$expected], got [$actual]"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "missing [$needle] in [$haystack]"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "unexpected [$needle] in [$haystack]"
  fi
}

assert_file() {
  local name="$1" path="$2"
  if [[ -f "$path" ]]; then
    pass "$name"
  else
    fail "$name" "missing file: $path"
  fi
}

capture() {
  local stderr_file="$TEST_ROOT/captured.stderr"
  : >"$stderr_file"
  if OUTPUT="$("$@" 2>"$stderr_file")"; then
    RC=0
  else
    RC=$?
  fi
  STDERR="$(cat "$stderr_file")"
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

meta_get_test() {
  local meta="$1" key="$2"
  sed -n "s/^${key}=//p" "$meta" | head -n 1
}

help_output="$($SCRIPT --help)"
assert_contains 'help documents result command' "$help_output" 'glm-agent result <worker-id>'
assert_contains 'help documents durable result status' "$help_output" 'STATUS=DONE|BLOCKED|INVALID'
assert_contains 'help explains close preserves history' "$help_output" 'does not delete its history'
assert_eq 'version is available' 'glm-agent 0.2.0' "$($SCRIPT --version)"

secret='zai-test-secret-value'
capture "$SCRIPT" api-key "$secret"
assert_eq 'api-key succeeds' '0' "$RC"
assert_not_contains 'api-key stdout hides secret' "$OUTPUT" "$secret"
assert_not_contains 'api-key stderr hides secret' "$STDERR" "$secret"
assert_eq 'api-key content is exact' "$secret" "$(cat "$GLM_AGENT_HOME/.env.auth")"
assert_eq 'credential directory is private' '700' "$(file_mode "$GLM_AGENT_HOME")"
assert_eq 'credential file is private' '600' "$(file_mode "$GLM_AGENT_HOME/.env.auth")"

: >"$FAKE_LOG"
parent_result="$TEST_ROOT/parent-result.md"
printf '%s\n' 'parent result sentinel' >"$parent_result"
export GLM_RESULT_FILE="$parent_result"
capture "$SCRIPT" run 'diagnostic prompt'
unset GLM_RESULT_FILE
assert_eq 'diagnostic run succeeds' '0' "$RC"
assert_eq 'diagnostic run returns worker stdout' 'RUN_OK' "$OUTPUT"
assert_eq 'diagnostic run cannot overwrite parent result' 'parent result sentinel' "$(cat "$parent_result")"
run_log="$(cat "$FAKE_LOG")"
assert_contains 'run uses Z.ai endpoint' "$run_log" 'base_url=https://api.z.ai/api/anthropic'
assert_contains 'run maps haiku alias' "$run_log" 'haiku=glm-5.3-flash[1m]'
assert_contains 'run maps sonnet alias' "$run_log" 'sonnet=glm-5.3[1m]'
assert_contains 'run maps opus alias' "$run_log" 'opus=glm-5.3[1m]'
assert_contains 'run unsets nested Claude marker' "$run_log" 'claudecode=unset'

: >"$FAKE_LOG"
start_stderr="$TEST_ROOT/start.stderr"
if start_output="$(
  cd "$PROJECT"
  "$SCRIPT" start 'implement the requested change' 2>"$start_stderr"
)"; then
  start_rc=0
else
  start_rc=$?
fi
assert_eq 'start succeeds for DONE result' '0' "$start_rc"
worker_id="$(printf '%s\n' "$start_output" | sed -n 's/^WORKER_ID=//p')"
result_path="$(printf '%s\n' "$start_output" | sed -n 's/^RESULT=//p')"
assert_contains 'start returns compact DONE status' "$start_output" \
  $'TURN=1\nROLE=general-purpose\nSTATUS=DONE\nRESULT='
assert_not_contains 'start does not print session id' "$start_output" 'SESSION_ID='
assert_file 'start creates task.md' "$GLM_AGENT_HOME/workers/$worker_id/task.md"
assert_file 'start preserves raw response' "$GLM_AGENT_HOME/workers/$worker_id/turns/0001/response.json"
assert_file 'start preserves stderr' "$GLM_AGENT_HOME/workers/$worker_id/turns/0001/stderr.log"
assert_file 'start creates durable result' "$result_path"
if [[ ! -e "$GLM_AGENT_HOME/workers/$worker_id/system-prompt.md" ]]; then
  pass 'start does not copy the directly read system prompt'
else
  fail 'start does not copy the directly read system prompt' 'unexpected worker-level system-prompt.md'
fi
assert_eq 'result ends with exact DONE marker' 'STATUS: DONE' "$(tail -n 1 "$result_path")"
meta="$GLM_AGENT_HOME/workers/$worker_id/meta"
assert_eq 'start stores original cwd' "$PROJECT" "$(meta_get_test "$meta" cwd)"
assert_eq 'start stores default model' 'sonnet' "$(meta_get_test "$meta" model)"
assert_eq 'start stores default role' 'general-purpose' "$(meta_get_test "$meta" role)"
assert_eq 'start stores session' 'session-1' "$(meta_get_test "$meta" claude_session_id)"
assert_eq 'start stores semantic status' 'DONE' "$(meta_get_test "$meta" status)"
start_log="$(cat "$FAKE_LOG")"
assert_contains 'start executes in original cwd' "$start_log" "cwd=$PROJECT"
assert_contains 'start supplies absolute result file' "$start_log" "result_file=$result_path"
assert_contains 'start appends worker contract' "$start_log" 'contract=present'
assert_contains 'start enables autonomous headless execution' "$start_log" 'permission_bypass=yes'
assert_contains 'start tells worker the exact result path' "$start_log" 'result_path_in_prompt=yes'
assert_contains 'start reads the configured prompt source' "$start_log" 'prompt_revision=one'
assert_contains 'default role prompt is loaded' "$start_log" 'role_prompt=general-purpose'
assert_contains 'start keeps 1M compact window' "$start_log" 'compact=1000000'
assert_contains 'start disables nonessential traffic' "$start_log" 'nonessential=1'
assert_contains 'start keeps API timeout' "$start_log" 'timeout=3000000'

capture "$SCRIPT" start --role invalid --cwd "$PROJECT" 'must not start'
assert_eq 'invalid role is rejected' '2' "$RC"
assert_contains 'invalid role error is clear' "$STDERR" 'invalid role: invalid'

: >"$FAKE_LOG"
write_test_system_prompt two
write_test_role_prompts two
send_stderr="$TEST_ROOT/send.stderr"
if send_output="$(
  cd "$OTHER_PROJECT"
  "$SCRIPT" send "$worker_id" 'RETURN_BLOCKED: external dependency unavailable' 2>"$send_stderr"
)"; then
  send_rc=0
else
  send_rc=$?
fi
assert_eq 'send treats BLOCKED as a valid turn' '0' "$send_rc"
assert_contains 'send returns compact BLOCKED status' "$send_output" \
  $'TURN=2\nROLE=general-purpose\nSTATUS=BLOCKED\nRESULT='
send_result="$(printf '%s\n' "$send_output" | sed -n 's/^RESULT=//p')"
assert_eq 'send result ends with exact BLOCKED marker' 'STATUS: BLOCKED' "$(tail -n 1 "$send_result")"
send_log="$(cat "$FAKE_LOG")"
assert_contains 'send resumes stored session' "$send_log" 'resume=session-1'
assert_contains 'send uses original cwd' "$send_log" "cwd=$PROJECT"
assert_contains 'send uses original model' "$send_log" 'model=sonnet'
assert_contains 'send reads the latest prompt source' "$send_log" 'prompt_revision=two'
assert_contains 'send reads the latest role prompt source' "$send_log" 'role_prompt_revision=two'
assert_contains 'send retains default role prompt' "$send_log" 'role_prompt=general-purpose'
assert_eq 'send advances stored turn' '2' "$(meta_get_test "$meta" turn)"
assert_eq 'send updates stored status' 'BLOCKED' "$(meta_get_test "$meta" status)"

capture "$SCRIPT" result "$worker_id"
assert_eq 'result prints latest canonical path' "$send_result" "$OUTPUT"

capture "$SCRIPT" status "$worker_id"
assert_eq 'status succeeds without invoking worker' '0' "$RC"
assert_contains 'status reports BLOCKED' "$OUTPUT" 'STATUS=BLOCKED'
assert_contains 'status reports original cwd' "$OUTPUT" "CWD=$PROJECT"
assert_not_contains 'status does not expose session id' "$OUTPUT" 'session-1'

capture "$SCRIPT" list
assert_eq 'list succeeds' '0' "$RC"
assert_contains 'list includes worker and state' "$OUTPUT" "$worker_id"
assert_contains 'list includes latest status' "$OUTPUT" 'BLOCKED'

: >"$FAKE_LOG"
capture "$SCRIPT" start --role explorer --model haiku --cwd "$OTHER_PROJECT" \
  'inspect the repository without changing it'
assert_eq 'explorer start succeeds' '0' "$RC"
explorer_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
assert_contains 'explorer start reports role' "$OUTPUT" 'ROLE=explorer'
explorer_meta="$GLM_AGENT_HOME/workers/$explorer_id/meta"
assert_eq 'explorer role is stored' 'explorer' \
  "$(meta_get_test "$explorer_meta" role)"
explorer_start_log="$(cat "$FAKE_LOG")"
assert_contains 'explorer role prompt is loaded' "$explorer_start_log" \
  'role_prompt=explorer'

: >"$FAKE_LOG"
capture "$SCRIPT" send "$explorer_id" 'continue the same investigation'
assert_eq 'explorer send succeeds' '0' "$RC"
assert_contains 'explorer send reports stored role' "$OUTPUT" 'ROLE=explorer'
assert_eq 'explorer send preserves model' 'haiku' \
  "$(meta_get_test "$explorer_meta" model)"
assert_eq 'explorer send preserves cwd' "$OTHER_PROJECT" \
  "$(meta_get_test "$explorer_meta" cwd)"
explorer_send_log="$(cat "$FAKE_LOG")"
assert_contains 'explorer send keeps role prompt' "$explorer_send_log" \
  'role_prompt=explorer'

parallel_one="$TEST_ROOT/parallel-one"
parallel_two="$TEST_ROOT/parallel-two"
mkdir -p "$parallel_one" "$parallel_two"
"$SCRIPT" start --role explorer --model haiku --cwd "$parallel_one" \
  'inspect worker one' >"$TEST_ROOT/parallel-one.out" &
pid_one=$!
"$SCRIPT" start --role general-purpose --model sonnet --cwd "$parallel_two" \
  'inspect worker two' >"$TEST_ROOT/parallel-two.out" &
pid_two=$!
wait "$pid_one"
wait "$pid_two"
parallel_id_one="$(sed -n 's/^WORKER_ID=//p' "$TEST_ROOT/parallel-one.out")"
parallel_id_two="$(sed -n 's/^WORKER_ID=//p' "$TEST_ROOT/parallel-two.out")"
if [[ "$parallel_id_one" != "$parallel_id_two" ]]; then
  pass 'parallel starts create distinct workers'
else
  fail 'parallel starts create distinct workers' "duplicate id: $parallel_id_one"
fi
assert_contains 'parallel explorer keeps role' \
  "$(cat "$TEST_ROOT/parallel-one.out")" 'ROLE=explorer'
assert_contains 'parallel general worker keeps role' \
  "$(cat "$TEST_ROOT/parallel-two.out")" 'ROLE=general-purpose'

: >"$FAKE_LOG"
capture "$SCRIPT" send "$worker_id" 'MISSING_RESULT'
assert_eq 'missing result is a protocol failure' '1' "$RC"
assert_contains 'missing result reports INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'missing result explains failure' "$OUTPUT" 'ERROR=result-file-missing'
assert_eq 'invalid turn is retained in history' '3' "$(meta_get_test "$meta" turn)"
assert_eq 'invalid turn updates worker status' 'INVALID' "$(meta_get_test "$meta" status)"
assert_eq 'invalid turn keeps prior canonical result' "$send_result" "$($SCRIPT result "$worker_id")"

capture "$SCRIPT" send "$worker_id" 'MALFORMED_RESULT'
assert_eq 'malformed result status is a protocol failure' '1' "$RC"
assert_contains 'malformed result reports INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'malformed result identifies status error' "$OUTPUT" 'ERROR=result-status-invalid'
assert_eq 'malformed result turn is retained' '4' "$(meta_get_test "$meta" turn)"

capture "$SCRIPT" send "$worker_id" 'CLAUDE_FAIL'
assert_eq 'nonzero Claude exit is an invocation failure' '1' "$RC"
assert_contains 'nonzero Claude exit reports INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'nonzero Claude exit code is retained' "$OUTPUT" 'ERROR=claude-exit-17'
assert_contains 'nonzero Claude stderr is preserved' "$(cat "$GLM_AGENT_HOME/workers/$worker_id/turns/0005/stderr.log")" 'simulated claude failure'

capture "$SCRIPT" send "$worker_id" 'BAD_JSON'
assert_eq 'malformed Claude JSON is an invocation failure' '1' "$RC"
assert_contains 'malformed Claude JSON reports INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'malformed Claude JSON identifies response error' "$OUTPUT" 'ERROR=invalid-response'
assert_eq 'malformed Claude JSON raw response is preserved' 'not-json' "$(cat "$GLM_AGENT_HOME/workers/$worker_id/turns/0006/response.json")"

capture "$SCRIPT" send "$worker_id" 'WRONG_SESSION'
assert_eq 'unexpected resumed session is an invocation failure' '1' "$RC"
assert_contains 'unexpected resumed session reports INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'unexpected resumed session identifies mismatch' "$OUTPUT" 'ERROR=unexpected-session-id'
assert_eq 'unexpected session does not replace stored session' 'session-1' "$(meta_get_test "$meta" claude_session_id)"

capture "$SCRIPT" close "$worker_id"
assert_eq 'close succeeds' '0' "$RC"
assert_contains 'close reports closed state' "$OUTPUT" 'CLOSED=true'
assert_eq 'close is persisted' 'true' "$(meta_get_test "$meta" closed)"
assert_file 'close preserves first response' "$GLM_AGENT_HOME/workers/$worker_id/turns/0001/response.json"
assert_file 'close preserves latest prompt' "$GLM_AGENT_HOME/workers/$worker_id/turns/0007/prompt.md"

capture "$SCRIPT" send "$worker_id" 'should be rejected'
assert_eq 'closed worker rejects send as CLI error' '2' "$RC"
assert_contains 'closed worker error is clear' "$STDERR" 'worker is closed'

capture "$SCRIPT" status '../escape'
assert_eq 'unsafe worker id is rejected' '2' "$RC"
assert_contains 'unsafe worker id error is clear' "$STDERR" 'invalid worker id'

noauth_home="$TEST_ROOT/noauth"
mkdir -p "$noauth_home"
noauth_stderr="$TEST_ROOT/noauth.stderr"
if OUTPUT="$(
  cd "$PROJECT"
  env -u ZAI_API_KEY GLM_AGENT_HOME="$noauth_home" "$SCRIPT" start 'must not create worker' 2>"$noauth_stderr"
)"; then
  noauth_rc=0
else
  noauth_rc=$?
fi
assert_eq 'missing credential is a CLI/configuration error' '2' "$noauth_rc"
assert_contains 'missing credential gives setup instruction' "$(cat "$noauth_stderr")" 'Run: glm-agent api-key'
if [[ ! -d "$noauth_home/workers" ]]; then
  pass 'missing credential does not create worker state'
else
  fail 'missing credential does not create worker state' "unexpected directory: $noauth_home/workers"
fi

printf '1..%d\n' "$tests"
if ((failures > 0)); then
  printf '# %d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '# all %d tests passed\n' "$tests"
