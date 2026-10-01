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
session_id_arg=""
model=""
append_prompt=""
permission_bypass="no"
invocation_mode="tui"

while (($#)); do
  case "$1" in
    --resume)
      resume_id="$2"
      shift 2
      ;;
    --session-id)
      session_id_arg="$2"
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
    -p)
      invocation_mode="headless"
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
  printf 'session_id_arg=%s\n' "$session_id_arg"
  printf 'invocation_mode=%s\n' "$invocation_mode"
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

if [[ "$invocation_mode" == "tui" ]]; then
  case "${FAKE_TUI_BEHAVIOR:-done}" in
    done)
      printf '# Summary\nCompleted in fake TUI\n\nSTATUS: DONE\n' \
        >"$GLM_RESULT_FILE"
      exit 0
      ;;
    blocked)
      printf '# Summary\nBlocked in fake TUI\n\nSTATUS: BLOCKED\n' \
        >"$GLM_RESULT_FILE"
      exit 0
      ;;
    missing)
      exit 0
      ;;
    malformed)
      printf '# Summary\nMalformed fake TUI result\n\nSTATUS: MAYBE\n' \
        >"$GLM_RESULT_FILE"
      exit 0
      ;;
    fail)
      printf '%s\n' 'simulated TUI failure' >&2
      exit 21
      ;;
  esac
fi

if [[ "$prompt" == *EXIT_ZERO_ZAI_ERROR* ]]; then
  printf '%s\n' \
    '{"type":"result","subtype":"error","is_error":true,"session_id":"session-1","error":{"code":1113,"message":"quota exhausted"}}'
  exit 0
fi

if [[ "$prompt" == *EXIT_ZERO_SUBTYPE_ERROR* ]]; then
  printf '%s\n' \
    '{"type":"result","subtype":"error","is_error":false,"session_id":"session-1","result":"provider failed with code 1305"}'
  exit 0
fi

if [[ "$prompt" == *EXIT_ZERO_ERROR_OBJECT* ]]; then
  printf '%s\n' \
    '{"type":"result","subtype":"success","session_id":"session-1","error":{"code":1310,"message":"quota exhausted"}}'
  exit 0
fi

if [[ "$prompt" == *EXIT_ZERO_RESULT_ERROR* ]]; then
  printf '%s\n' \
    '{"type":"result","session_id":"session-1","result":"Z.ai quota error: code 1113 quota exhausted"}'
  exit 0
fi

if [[ "$prompt" == *EXIT_ZERO_BARE_FAILED_ERROR* ]]; then
  printf '%s\n' \
    '{"type":"result","session_id":"session-1","result":"provider failed with code 1305"}'
  exit 0
fi

if [[ "$prompt" == *UNRELATED_NUMBER_NO_ERROR* ]]; then
  printf '# Summary\nCompleted by fake worker\n\nSTATUS: DONE\n' >"$GLM_RESULT_FILE"
  printf '%s\n' \
    '{"type":"result","session_id":"session-1","result":"unrelated text mentioning 10010 only"}'
  exit 0
fi

if [[ "$prompt" == *EXIT_ZERO_BRACKET_QUOTA_ERROR* ]]; then
  printf '%s\n' \
    '{"type":"result","session_id":"session-1","result":"API Error: Request rejected (429) · [1308][Usage limit reached for 5 hour. Your limit will reset at ...][...]"}'
  exit 0
fi

if [[ "$prompt" =~ ZAI_ERROR_([0-9]+) ]]; then
  zai_code="${BASH_REMATCH[1]}"
  printf '{"error":{"code":"%s","message":"simulated provider error"}}\n' \
    "$zai_code" >&2
  exit 1
fi

if [[ "$prompt" == *CLAUDE_FAIL* ]]; then
  printf '%s\n' 'simulated claude failure' >&2
  exit 17
fi

if [[ "$prompt" == *WAIT_FOR_RELEASE* ]]; then
  : >"$FAKE_CLAUDE_BLOCK_STARTED"
  for _ in {1..500}; do
    [[ -f "$FAKE_CLAUDE_BLOCK_RELEASE" ]] && break
    sleep 0.01
  done
  [[ -f "$FAKE_CLAUDE_BLOCK_RELEASE" ]] || {
    printf '%s\n' 'timed out waiting for test release' >&2
    exit 18
  }
fi

if [[ "$prompt" == *HANG_WITH_CHILD* ]]; then
  if [[ "$prompt" == *HANG_WITH_TERM_IGNORING_CHILD* ]]; then
    /bin/bash -c 'trap "" TERM; while :; do sleep 1; done' &
  else
    sleep 60 &
  fi
  fake_child_pid=$!
  printf '%s\n' "$fake_child_pid" >"$FAKE_CLAUDE_CHILD_PID_FILE"
  ps -o pgid= -p "$$" | tr -d ' ' >"$FAKE_CLAUDE_PROVIDER_PGID_FILE"
  : >"$FAKE_CLAUDE_HANG_STARTED"
  cleanup_fake_child() {
    kill -KILL "$fake_child_pid" 2>/dev/null || true
    wait "$fake_child_pid" 2>/dev/null || true
  }
  if [[ "$prompt" != *HANG_WITH_TERM_IGNORING_CHILD* ]]; then
    trap cleanup_fake_child EXIT
  fi
  for _ in {1..1000}; do
    [[ -f "$FAKE_CLAUDE_HANG_RELEASE" ]] && break
    sleep 0.01
  done
  [[ -f "$FAKE_CLAUDE_HANG_RELEASE" ]] || exit 19
fi

if [[ "$prompt" == *ERROR_WITH_TERM_IGNORING_CHILD* ]]; then
  /bin/bash -c 'trap "" TERM; while :; do sleep 1; done' &
  error_child_pid=$!
  printf '%s\n' "$error_child_pid" >"$FAKE_CLAUDE_CHILD_PID_FILE"
  ps -o pgid= -p "$$" | tr -d ' ' >"$FAKE_CLAUDE_PROVIDER_PGID_FILE"
  printf '%s\n' \
    '{"type":"result","session_id":"session-1","result":"Z.ai quota error: code 1113 quota exhausted"}'
  exit 0
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

if [[ "$prompt" == *FIXED_ERROR_CODE_REPORT* ]]; then
  printf '%s\n' \
    '{"type":"result","subtype":"success","is_error":false,"session_id":"session-1","result":"Fixed Z.ai authentication code 1001 and tests pass"}'
  exit 0
fi

if [[ "$prompt" == *PERSISTENT_BACKGROUND_CHILD* ]]; then
  /usr/bin/nohup /bin/bash -c 'trap "" TERM; while :; do sleep 1; done' \
    >/dev/null 2>&1 &
  persistent_child_pid=$!
  printf '%s\n' "$persistent_child_pid" >"$FAKE_CLAUDE_CHILD_PID_FILE"
  ps -o pgid= -p "$persistent_child_pid" | tr -d ' ' \
    >"$FAKE_CLAUDE_PROVIDER_PGID_FILE"
fi

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

process_start_test() {
  ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^[[:space:]]*//' \
    -e 's/[[:space:]]*$//'
}

process_is_running_test() {
  local state

  state="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  [[ -n "$state" && "$state" != Z* ]]
}

help_output="$($SCRIPT --help)"
assert_contains 'help documents result command' "$help_output" 'glm-agent result <worker-id>'
assert_contains 'help documents durable result status' "$help_output" 'STATUS=DONE|BLOCKED|INVALID'
assert_contains 'help explains close preserves history' "$help_output" 'does not delete its history'
assert_contains 'help documents role option' "$help_output" \
  'start [--role <role>] [--model <alias>]'
assert_contains 'help documents explorer role' "$help_output" 'explorer'
assert_contains 'help documents fallback signal' "$help_output" \
  'FALLBACK_RECOMMENDED'
assert_contains 'help documents managed TUI' "$help_output" \
  'glm-agent tui [--role <role>] [--model <alias>] [--cwd <directory>]'
assert_contains 'help documents async start' "$help_output" \
  'glm-agent start --async'
assert_contains 'help documents async send' "$help_output" \
  'glm-agent send --async <worker-id> <message>'
assert_contains 'help documents bounded wait' "$help_output" \
  'glm-agent wait [--timeout <seconds>] <worker-id>'
assert_contains 'help documents cancellation' "$help_output" \
  'glm-agent cancel <worker-id>'
assert_contains 'help distinguishes launch from completion' "$help_output" \
  'RUNNING is a launch receipt, not task completion.'
assert_contains 'help distinguishes parent stop from worker cancel' "$help_output" \
  'Stopping a parent Claude turn leaves a detached worker running.'
assert_contains 'help lists quota in the usage synopsis' "$help_output" \
  $'\n  glm-agent quota\n'
assert_contains 'help documents the quota command' "$help_output" \
  $'\n    quota\n'
assert_contains 'help documents quota status values' "$help_output" \
  'QUOTA_STATUS=OK|INVALID'
assert_contains 'help documents the quota window format' "$help_output" \
  'LIMIT_<i>_WINDOW=<n>h|<n>w|u<unit>x<number>|<empty>'
for quota_field in 'PLAN_LEVEL=' 'LIMIT_COUNT=' 'LIMIT_<i>_TYPE=' \
  'LIMIT_<i>_TOTAL=' 'LIMIT_<i>_USED=' 'LIMIT_<i>_REMAINING=' \
  'LIMIT_<i>_USED_PERCENT=' 'LIMIT_<i>_RESET_AT='; do
  assert_contains "help documents quota field $quota_field" "$help_output" \
    "$quota_field"
done
assert_contains 'help documents the quota success exit' "$help_output" \
  'quota exits 0 for QUOTA_STATUS=OK'
assert_contains 'help documents the quota failure exit' "$help_output" \
  'quota exits 1 when the lookup failed'
assert_contains 'help documents the quota stdin header' "$help_output" \
  'HTTP header that curl reads from'
assert_eq 'version is available' 'glm-agent 0.5.0' "$($SCRIPT --version)"

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
  $'TURN=1\nMODEL=sonnet\nROLE=general-purpose\nSTATUS=DONE\nRESULT='
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
  $'TURN=2\nMODEL=sonnet\nROLE=general-purpose\nSTATUS=BLOCKED\nRESULT='
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

capture "$SCRIPT" send "$worker_id" 'EXIT_ZERO_ZAI_ERROR'
assert_eq 'exit-zero provider error fails the turn' '1' "$RC"
assert_contains 'exit-zero quota error is classified' "$OUTPUT" \
  'ERROR_KIND=quota-exhausted'
assert_contains 'exit-zero quota code is retained' "$OUTPUT" \
  'PROVIDER_CODE=1113'
assert_contains 'exit-zero quota error recommends fallback' "$OUTPUT" \
  'FALLBACK_RECOMMENDED=true'

capture "$SCRIPT" send "$worker_id" 'EXIT_ZERO_SUBTYPE_ERROR'
assert_eq 'exit-zero subtype error fails the turn' '1' "$RC"
assert_contains 'subtype-only provider error is classified' "$OUTPUT" \
  'ERROR_KIND=provider-transient'
assert_contains 'subtype-only provider code is retained' "$OUTPUT" \
  'PROVIDER_CODE=1305'

capture "$SCRIPT" send "$worker_id" 'EXIT_ZERO_ERROR_OBJECT'
assert_eq 'exit-zero error object fails the turn' '1' "$RC"
assert_contains 'error-object quota is classified' "$OUTPUT" \
  'ERROR_KIND=quota-exhausted'
assert_contains 'error-object provider code is retained' "$OUTPUT" \
  'PROVIDER_CODE=1310'

capture "$SCRIPT" send "$worker_id" 'EXIT_ZERO_RESULT_ERROR'
assert_eq 'exit-zero result text error fails the turn' '1' "$RC"
assert_contains 'result-text quota is classified' "$OUTPUT" \
  'ERROR_KIND=quota-exhausted'
assert_contains 'result-text provider code is retained' "$OUTPUT" \
  'PROVIDER_CODE=1113'

capture "$SCRIPT" send "$worker_id" 'EXIT_ZERO_BARE_FAILED_ERROR'
assert_eq 'unstructured bare failed error fails the turn' '1' "$RC"
assert_contains 'unstructured bare failed error is classified' "$OUTPUT" \
  'ERROR_KIND=provider-transient'
assert_contains 'unstructured bare failed error code is retained' "$OUTPUT" \
  'PROVIDER_CODE=1305'

capture "$SCRIPT" send "$worker_id" 'UNRELATED_NUMBER_NO_ERROR'
assert_eq 'unrelated number without error keywords succeeds' '0' "$RC"
assert_contains 'unrelated number without error keywords reaches DONE' "$OUTPUT" \
  'STATUS=DONE'

capture "$SCRIPT" send "$worker_id" 'EXIT_ZERO_BRACKET_QUOTA_ERROR'
assert_eq 'bracket-format Z.ai quota error fails the turn' '1' "$RC"
assert_contains 'bracket-format quota code is extracted' "$OUTPUT" \
  'PROVIDER_CODE=1308'
assert_contains 'bracket-format quota error is classified' "$OUTPUT" \
  'ERROR_KIND=quota-exhausted'
assert_contains 'bracket-format quota error recommends fallback' "$OUTPUT" \
  'FALLBACK_RECOMMENDED=true'

export FAKE_CLAUDE_CHILD_PID_FILE="$TEST_ROOT/error-path.child.pid"
export FAKE_CLAUDE_PROVIDER_PGID_FILE="$TEST_ROOT/error-path.provider.pgid"
capture "$SCRIPT" send "$worker_id" 'ERROR_WITH_TERM_IGNORING_CHILD'
assert_eq 'provider error path fails the turn' '1' "$RC"
assert_contains 'provider error path is classified quota-exhausted' "$OUTPUT" \
  'ERROR_KIND=quota-exhausted'
error_path_child_pid="$(cat "$FAKE_CLAUDE_CHILD_PID_FILE" 2>/dev/null || true)"
if [[ "$error_path_child_pid" =~ ^[0-9]+$ ]]; then
  pass 'provider error path recorded a background child'
else
  fail 'provider error path recorded a background child' \
    'no child pid was recorded'
fi
for _ in {1..300}; do
  if ! process_is_running_test "$error_path_child_pid"; then
    break
  fi
  sleep 0.01
done
if ! process_is_running_test "$error_path_child_pid"; then
  pass 'a pure provider-error turn still drains its TERM-ignoring child'
else
  fail 'a pure provider-error turn still drains its TERM-ignoring child' \
    "child $error_path_child_pid is still alive"
fi
unset FAKE_CLAUDE_CHILD_PID_FILE FAKE_CLAUDE_PROVIDER_PGID_FILE

capture "$SCRIPT" send "$worker_id" 'FIXED_ERROR_CODE_REPORT'
assert_eq 'successful error-code report stays successful' '0' "$RC"
assert_contains 'successful error-code report reaches DONE' "$OUTPUT" \
  'STATUS=DONE'

export FAKE_CLAUDE_CHILD_PID_FILE="$TEST_ROOT/persistent.child.pid"
export FAKE_CLAUDE_PROVIDER_PGID_FILE="$TEST_ROOT/persistent.provider.pgid"
capture "$SCRIPT" send "$worker_id" 'PERSISTENT_BACKGROUND_CHILD'
assert_eq 'successful persistent background turn completes' '0' "$RC"
persistent_child_pid="$(cat "$FAKE_CLAUDE_CHILD_PID_FILE")"
persistent_provider_pgid="$(cat "$FAKE_CLAUDE_PROVIDER_PGID_FILE")"
if process_is_running_test "$persistent_child_pid"; then
  pass 'successful turn preserves its verified background process'
else
  fail 'successful turn preserves its verified background process' \
    "background child was stopped: $persistent_child_pid"
fi
kill -KILL -- "-$persistent_provider_pgid" 2>/dev/null || true
unset FAKE_CLAUDE_CHILD_PID_FILE FAKE_CLAUDE_PROVIDER_PGID_FILE

export FAKE_CLAUDE_BLOCK_STARTED="$TEST_ROOT/error-reset.started"
export FAKE_CLAUDE_BLOCK_RELEASE="$TEST_ROOT/error-reset.release"
capture "$SCRIPT" send --async "$worker_id" \
  'WAIT_FOR_RELEASE clear prior error metadata'
assert_eq 'async retry after failure starts' '0' "$RC"
for _ in {1..500}; do
  [[ -f "$FAKE_CLAUDE_BLOCK_STARTED" ]] && break
  sleep 0.01
done
capture "$SCRIPT" wait --timeout 0 "$worker_id"
assert_contains 'running retry clears prior error kind' "$OUTPUT" \
  $'ERROR_KIND=\n'
assert_not_contains 'running retry hides prior quota error' "$OUTPUT" \
  'ERROR_KIND=quota-exhausted'
: >"$FAKE_CLAUDE_BLOCK_RELEASE"
capture "$SCRIPT" wait --timeout 5 "$worker_id"
assert_eq 'async retry after failure completes' '0' "$RC"
send_result="$("$SCRIPT" result "$worker_id")"
unset FAKE_CLAUDE_BLOCK_STARTED FAKE_CLAUDE_BLOCK_RELEASE

capture "$SCRIPT" start --cwd "$PROJECT" 'lock test worker'
assert_eq 'lock test worker starts' '0' "$RC"
lock_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
export FAKE_CLAUDE_BLOCK_STARTED="$TEST_ROOT/block.started"
export FAKE_CLAUDE_BLOCK_RELEASE="$TEST_ROOT/block.release"
"$SCRIPT" send "$lock_worker_id" 'WAIT_FOR_RELEASE' \
  >"$TEST_ROOT/blocking-send.out" 2>"$TEST_ROOT/blocking-send.err" &
blocking_send_pid=$!
for _ in {1..500}; do
  [[ -f "$FAKE_CLAUDE_BLOCK_STARTED" ]] && break
  sleep 0.01
done
if [[ -f "$FAKE_CLAUDE_BLOCK_STARTED" ]]; then
  pass 'first overlapping send reaches the provider'
else
  fail 'first overlapping send reaches the provider' 'provider did not start'
fi
capture "$SCRIPT" send "$lock_worker_id" 'overlapping send must be rejected'
assert_eq 'overlapping send is a CLI state error' '2' "$RC"
assert_contains 'overlapping send reports active worker' "$STDERR" \
  'worker is active'
: >"$FAKE_CLAUDE_BLOCK_RELEASE"
if wait "$blocking_send_pid"; then
  pass 'first overlapping send completes after release'
else
  fail 'first overlapping send completes after release' \
    "$(cat "$TEST_ROOT/blocking-send.err")"
fi
unset FAKE_CLAUDE_BLOCK_STARTED FAKE_CLAUDE_BLOCK_RELEASE

sync_interrupt_started="$TEST_ROOT/sync-interrupt.started"
sync_interrupt_release="$TEST_ROOT/sync-interrupt.release"
sync_interrupt_child_file="$TEST_ROOT/sync-interrupt.child.pid"
sync_interrupt_pgid_file="$TEST_ROOT/sync-interrupt.provider.pgid"
export FAKE_CLAUDE_HANG_STARTED="$sync_interrupt_started"
export FAKE_CLAUDE_HANG_RELEASE="$sync_interrupt_release"
export FAKE_CLAUDE_CHILD_PID_FILE="$sync_interrupt_child_file"
export FAKE_CLAUDE_PROVIDER_PGID_FILE="$sync_interrupt_pgid_file"
"$SCRIPT" start --cwd "$PROJECT" \
  'HANG_WITH_CHILD HANG_WITH_TERM_IGNORING_CHILD sync interruption' \
  >"$TEST_ROOT/sync-interrupt.out" 2>"$TEST_ROOT/sync-interrupt.err" &
sync_wrapper_pid=$!
for _ in {1..500}; do
  [[ -f "$sync_interrupt_started" && -s "$sync_interrupt_child_file" ]] && break
  sleep 0.01
done
sync_child_pid="$(cat "$sync_interrupt_child_file" 2>/dev/null || true)"
kill -TERM "$sync_wrapper_pid" 2>/dev/null || true
for _ in {1..300}; do
  if [[ -z "$sync_child_pid" ]] || ! process_is_running_test "$sync_child_pid"; then
    break
  fi
  sleep 0.01
done
if [[ -n "$sync_child_pid" ]] && ! process_is_running_test "$sync_child_pid"; then
  pass 'sync interruption terminates provider child processes'
else
  fail 'sync interruption terminates provider child processes' \
    "provider child remains after wrapper TERM: $sync_child_pid"
fi
: >"$sync_interrupt_release"
wait "$sync_wrapper_pid" 2>/dev/null || true
unset FAKE_CLAUDE_HANG_STARTED FAKE_CLAUDE_HANG_RELEASE \
  FAKE_CLAUDE_CHILD_PID_FILE FAKE_CLAUDE_PROVIDER_PGID_FILE

async_started="$TEST_ROOT/async.started"
async_release="$TEST_ROOT/async.release"
async_receipt="$TEST_ROOT/async.receipt"
export FAKE_CLAUDE_BLOCK_STARTED="$async_started"
export FAKE_CLAUDE_BLOCK_RELEASE="$async_release"
if PATH="$FAKE_BIN:/usr/bin:/bin" /bin/bash -c '
  set -m
  "$1" start --async --role explorer --model haiku --cwd "$2" \
    "WAIT_FOR_RELEASE async orphaned launcher" >"$3"
' _ "$SCRIPT" "$PROJECT" "$async_receipt" \
  2>"$TEST_ROOT/async-start.err"; then
  async_start_rc=0
else
  async_start_rc=$?
fi
assert_eq 'async start parent shell exits successfully' '0' "$async_start_rc"
async_output="$(cat "$async_receipt")"
async_worker_id="$(printf '%s\n' "$async_output" | sed -n 's/^WORKER_ID=//p')"
assert_contains 'async start returns a RUNNING receipt' "$async_output" \
  $'TURN=1\nMODEL=haiku\nROLE=explorer\nSTATUS=RUNNING\nRESULT='
for _ in {1..500}; do
  [[ -f "$async_started" ]] && break
  sleep 0.01
done
if [[ -f "$async_started" ]]; then
  pass 'detached runner survives its launching shell'
else
  fail 'detached runner survives its launching shell' \
    "$(cat "$TEST_ROOT/async-start.err")"
fi

capture "$SCRIPT" status "$async_worker_id"
assert_eq 'status observes an async worker' '0' "$RC"
assert_contains 'status reports active headless mode' "$OUTPUT" \
  'ACTIVE_MODE=headless'
assert_contains 'status reports active turn' "$OUTPUT" 'ACTIVE_TURN=1'

async_state="$GLM_AGENT_HOME/workers/$async_worker_id/active/state"
async_runner_pid="$(sed -n 's/^runner_pid=//p' "$async_state")"
async_runner_pgid="$(ps -o pgid= -p "$async_runner_pid" | tr -d ' ')"
assert_eq 'async runner leads its own process group' "$async_runner_pid" \
  "$async_runner_pgid"
for _ in {1..100}; do
  if ! kill -0 "$async_runner_pid" 2>/dev/null; then
    break
  fi
  sleep 0.01
done
if kill -0 "$async_runner_pid" 2>/dev/null; then
  pass 'recorded async runner remains alive while provider runs'
else
  fail 'recorded async runner remains alive while provider runs' \
    "runner $async_runner_pid exited before provider completion"
fi

capture "$SCRIPT" wait --timeout 0 "$async_worker_id"
assert_eq 'zero-timeout wait is a successful observation' '0' "$RC"
assert_contains 'zero-timeout wait reports RUNNING' "$OUTPUT" 'STATUS=RUNNING'
assert_contains 'zero-timeout wait distinguishes timeout' "$OUTPUT" \
  'WAIT_RESULT=TIMEOUT'

capture "$SCRIPT" close "$async_worker_id"
assert_eq 'close rejects an active async worker' '2' "$RC"
assert_contains 'active close error is clear' "$STDERR" 'worker is active'

: >"$async_release"
capture "$SCRIPT" wait --timeout 5 "$async_worker_id"
assert_eq 'wait returns after async completion' '0' "$RC"
assert_contains 'terminal wait reports DONE' "$OUTPUT" 'STATUS=DONE'
assert_contains 'terminal wait identifies terminal state' "$OUTPUT" \
  'WAIT_RESULT=TERMINAL'
async_result="$(printf '%s\n' "$OUTPUT" | sed -n 's/^RESULT=//p')"
assert_file 'async turn creates its durable result' "$async_result"
assert_file 'async turn keeps a detached runner log' \
  "$GLM_AGENT_HOME/workers/$async_worker_id/turns/0001/runner.log"

rm -f "$async_started" "$async_release"
capture "$SCRIPT" send --async "$async_worker_id" \
  'WAIT_FOR_RELEASE async resume'
assert_eq 'async send returns successfully' '0' "$RC"
assert_contains 'async send returns turn two receipt' "$OUTPUT" \
  $'TURN=2\nMODEL=haiku\nROLE=explorer\nSTATUS=RUNNING\nRESULT='
for _ in {1..500}; do
  [[ -f "$async_started" ]] && break
  sleep 0.01
done
: >"$async_release"
capture "$SCRIPT" wait --timeout 5 "$async_worker_id"
assert_eq 'async resumed turn reaches terminal state' '0' "$RC"
assert_contains 'async resumed turn completes' "$OUTPUT" 'STATUS=DONE'
async_log="$(cat "$FAKE_LOG")"
assert_contains 'async send resumes the stored session' "$async_log" \
  'resume=session-1'
assert_contains 'async send uses the stored cwd' "$async_log" "cwd=$PROJECT"
unset FAKE_CLAUDE_BLOCK_STARTED FAKE_CLAUDE_BLOCK_RELEASE

cancel_started="$TEST_ROOT/cancel.started"
cancel_release="$TEST_ROOT/cancel.release"
cancel_child_pid_file="$TEST_ROOT/cancel.child.pid"
cancel_provider_pgid_file="$TEST_ROOT/cancel.provider.pgid"
export FAKE_CLAUDE_HANG_STARTED="$cancel_started"
export FAKE_CLAUDE_HANG_RELEASE="$cancel_release"
export FAKE_CLAUDE_CHILD_PID_FILE="$cancel_child_pid_file"
export FAKE_CLAUDE_PROVIDER_PGID_FILE="$cancel_provider_pgid_file"
capture "$SCRIPT" start --async --cwd "$PROJECT" \
  'HANG_WITH_CHILD HANG_WITH_TERM_IGNORING_CHILD cancel me'
assert_eq 'cancel test async worker starts' '0' "$RC"
cancel_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
for _ in {1..500}; do
  [[ -f "$cancel_started" && -s "$cancel_child_pid_file" ]] && break
  sleep 0.01
done
cancel_child_pid="$(cat "$cancel_child_pid_file" 2>/dev/null || true)"
cancel_provider_pgid="$(cat "$cancel_provider_pgid_file" 2>/dev/null || true)"
if [[ -n "$cancel_child_pid" ]] && kill -0 "$cancel_child_pid" 2>/dev/null; then
  pass 'cancel test provider child is running'
else
  fail 'cancel test provider child is running' 'provider child did not start'
fi
capture "$SCRIPT" cancel "$cancel_worker_id"
cancel_rc="$RC"
cancel_output="$OUTPUT"
if ((cancel_rc != 0)); then
  : >"$cancel_release"
fi
assert_eq 'cancel succeeds for an active async worker' '0' "$cancel_rc"
assert_contains 'cancel reports INVALID terminal status' "$cancel_output" \
  'STATUS=INVALID'
assert_contains 'cancel classifies interruption' "$cancel_output" \
  'ERROR_KIND=interrupted'
assert_contains 'cancel reports cancellation result' "$cancel_output" \
  'CANCEL_RESULT=CANCELLED'
for _ in {1..300}; do
  if ! process_is_running_test "$cancel_child_pid"; then
    break
  fi
  sleep 0.01
done
if ! process_is_running_test "$cancel_child_pid"; then
  pass 'cancel terminates provider child processes'
else
  fail 'cancel terminates provider child processes' \
    "child $cancel_child_pid remains in provider group $cancel_provider_pgid"
fi

capture "$SCRIPT" start --cwd "$PROJECT" 'forged provider identity fixture'
assert_eq 'forged provider fixture starts' '0' "$RC"
forged_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
forged_dir="$GLM_AGENT_HOME/workers/$forged_worker_id"
forged_generation='forged-generation'
forged_old_marker="$forged_dir/active/cancel.requested"
forged_new_marker="$forged_dir/cancel.$forged_generation.requested"
/bin/bash -c '
  while [[ ! -f "$1" && ! -f "$2" ]]; do sleep 0.01; done
' _ "$forged_old_marker" "$forged_new_marker" \
  "_execute-turn $forged_worker_id 2" &
forged_runner_pid=$!
set -m
sleep 60 &
protected_provider_pid=$!
set +m
protected_provider_pgid="$(ps -o pgid= -p "$protected_provider_pid" | tr -d ' ')"
mkdir "$forged_dir/turns/0002" "$forged_dir/active"
printf '%s\n' 'headless' >"$forged_dir/turns/0002/mode"
printf '%s\n' 'forged provider must survive' >"$forged_dir/turns/0002/prompt.md"
cat >"$forged_dir/active/state" <<EOF
generation=$forged_generation
mode=headless
turn=2
supervision=async
runner_pid=$forged_runner_pid
runner_start=$(process_start_test "$forged_runner_pid")
provider_pid=$protected_provider_pid
provider_pgid=$protected_provider_pgid
provider_start=forged-start-identity
started_at=$(date +%s)
EOF
sed 's/^status=.*/status=RUNNING/; s/^turn=.*/turn=2/' \
  "$forged_dir/meta" >"$forged_dir/meta.next"
mv "$forged_dir/meta.next" "$forged_dir/meta"
capture "$SCRIPT" cancel "$forged_worker_id"
assert_eq 'cancel handles forged provider identity safely' '0' "$RC"
if kill -0 "$protected_provider_pid" 2>/dev/null; then
  pass 'cancel does not signal a provider with mismatched start identity'
else
  fail 'cancel does not signal a provider with mismatched start identity' \
    "protected provider group was signalled: $protected_provider_pgid"
fi
kill -TERM -- "-$protected_provider_pgid" 2>/dev/null || true
wait "$protected_provider_pid" 2>/dev/null || true
wait "$forged_runner_pid" 2>/dev/null || true

capture "$SCRIPT" cancel "$cancel_worker_id"
assert_eq 'repeated cancel is idempotent' '0' "$RC"
assert_contains 'repeated cancel reports terminal worker' "$OUTPUT" \
  'CANCEL_RESULT=ALREADY_TERMINAL'

capture "$SCRIPT" cancel "$async_worker_id"
assert_eq 'cancel after natural completion is idempotent' '0' "$RC"
assert_contains 'natural terminal state is preserved on cancel' "$OUTPUT" \
  'STATUS=DONE'
assert_contains 'completed cancel reports already terminal' "$OUTPUT" \
  'CANCEL_RESULT=ALREADY_TERMINAL'

capture "$SCRIPT" start --cwd "$PROJECT" 'cancel replacement race fixture'
assert_eq 'cancel replacement race fixture starts' '0' "$RC"
cancel_race_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
cancel_race_dir="$GLM_AGENT_HOME/workers/$cancel_race_worker_id"
sed 's/^status=.*/status=RUNNING/; s/^turn=.*/turn=2/' \
  "$cancel_race_dir/meta" >"$cancel_race_dir/meta.next"
mv "$cancel_race_dir/meta.next" "$cancel_race_dir/meta"
mkdir "$cancel_race_dir/turns/0002"
printf 'headless\n' >"$cancel_race_dir/turns/0002/mode"
printf 'cancel race decoy turn\n' >"$cancel_race_dir/turns/0002/prompt.md"
/bin/bash -c 'trap "" TERM; while :; do sleep 1; done' \
  _ "_execute-turn $cancel_race_worker_id 2" &
cancel_race_decoy_pid=$!
mkdir "$cancel_race_dir/active"
cat >"$cancel_race_dir/active/state" <<EOF
generation=cancel-race-gen-1
mode=headless
turn=2
supervision=async
runner_pid=$cancel_race_decoy_pid
runner_start=$(process_start_test "$cancel_race_decoy_pid")
provider_pid=
provider_pgid=
provider_start=
started_at=$(date +%s)
EOF
(
  sleep 0.3
  rm -f "$cancel_race_dir/active/state" "$cancel_race_dir/active/cancel.requested" \
    "$cancel_race_dir/active/launch.ready"
  rmdir "$cancel_race_dir/active" 2>/dev/null || true
  mkdir "$cancel_race_dir/turns/0003"
  printf 'headless\n' >"$cancel_race_dir/turns/0003/mode"
  printf 'replacement turn started mid-cancel\n' >"$cancel_race_dir/turns/0003/prompt.md"
  mkdir "$cancel_race_dir/active"
  cat >"$cancel_race_dir/active/state" <<EOF2
generation=cancel-race-gen-2
mode=headless
turn=3
supervision=async
runner_pid=$$
runner_start=$(process_start_test "$$")
provider_pid=
provider_pgid=
provider_start=
started_at=$(date +%s)
EOF2
) &
cancel_race_replacement_pid=$!
if cancel_race_output="$(gtimeout 10 "$SCRIPT" cancel "$cancel_race_worker_id" \
  2>"$TEST_ROOT/cancel-race.err")"; then
  cancel_race_rc=0
else
  cancel_race_rc=$?
fi
wait "$cancel_race_replacement_pid" 2>/dev/null || true
kill -KILL "$cancel_race_decoy_pid" 2>/dev/null || true
wait "$cancel_race_decoy_pid" 2>/dev/null || true
assert_eq 'cancel with a replacement race does not crash' '0' "$cancel_race_rc"
if [[ "$cancel_race_output" == *'STATUS=RUNNING'* &&
   "$cancel_race_output" == *'CANCEL_RESULT=CANCELLED'* ]]; then
  fail 'cancel never reports RUNNING and CANCELLED together' \
    "$cancel_race_output"
else
  pass 'cancel never reports RUNNING and CANCELLED together'
fi
assert_not_contains 'cancel replacement race final status is not falsely cancelled' \
  "$cancel_race_output" 'CANCEL_RESULT=CANCELLED'
rm -f "$cancel_race_dir/active/state"
rmdir "$cancel_race_dir/active" 2>/dev/null || true

capture "$SCRIPT" start --cwd "$PROJECT" 'pre-provider cancel fixture'
assert_eq 'pre-provider cancel fixture starts' '0' "$RC"
pre_cancel_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
pre_cancel_dir="$GLM_AGENT_HOME/workers/$pre_cancel_worker_id"
mkdir "$pre_cancel_dir/turns/0002" "$pre_cancel_dir/active"
printf '%s\n' 'headless' >"$pre_cancel_dir/turns/0002/mode"
printf '%s\n' 'provider must not start' >"$pre_cancel_dir/turns/0002/prompt.md"
cat >"$pre_cancel_dir/active/state" <<EOF
generation=pre-provider-generation
mode=headless
turn=2
supervision=async
runner_pid=
runner_start=
provider_pid=
provider_pgid=
provider_start=
started_at=$(date +%s)
EOF
sed 's/^status=.*/status=RUNNING/; s/^turn=.*/turn=2/' \
  "$pre_cancel_dir/meta" >"$pre_cancel_dir/meta.next"
mv "$pre_cancel_dir/meta.next" "$pre_cancel_dir/meta"
"$SCRIPT" _execute-turn "$pre_cancel_worker_id" 2 \
  >"$pre_cancel_dir/turns/0002/runner.log" 2>&1 &
pre_cancel_runner_pid=$!
sed "s/^runner_pid=.*/runner_pid=$pre_cancel_runner_pid/; s|^runner_start=.*|runner_start=$(process_start_test "$pre_cancel_runner_pid")|" \
  "$pre_cancel_dir/active/state" >"$pre_cancel_dir/active/state.next"
mv "$pre_cancel_dir/active/state.next" "$pre_cancel_dir/active/state"
pre_cancel_started_at="$(date +%s)"
capture "$SCRIPT" cancel "$pre_cancel_worker_id"
pre_cancel_elapsed="$(( $(date +%s) - pre_cancel_started_at ))"
assert_eq 'cancel before provider startup succeeds' '0' "$RC"
assert_contains 'pre-provider cancel is interrupted' "$OUTPUT" \
  'ERROR_KIND=interrupted'
if ((pre_cancel_elapsed <= 2)); then
  pass 'pre-provider cancel does not wait for launch timeout'
else
  fail 'pre-provider cancel does not wait for launch timeout' \
    "cancel took ${pre_cancel_elapsed}s"
fi
unset FAKE_CLAUDE_HANG_STARTED FAKE_CLAUDE_HANG_RELEASE \
  FAKE_CLAUDE_CHILD_PID_FILE FAKE_CLAUDE_PROVIDER_PGID_FILE

: >"$FAKE_LOG"
capture "$SCRIPT" tui --role explorer --model haiku --cwd "$OTHER_PROJECT"
assert_eq 'new managed TUI exits successfully' '0' "$RC"
tui_output="$OUTPUT"
tui_worker_id="$(printf '%s\n' "$tui_output" | sed -n 's/^WORKER_ID=//p' | head -n 1)"
assert_contains 'new TUI prints a pre-launch receipt' "$tui_output" \
  $'TURN=1\nMODEL=haiku\nROLE=explorer\nSTATUS=RUNNING\nRESULT='
assert_contains 'new TUI prints terminal status after exit' "$tui_output" \
  'STATUS=DONE'
tui_dir="$GLM_AGENT_HOME/workers/$tui_worker_id"
tui_meta="$tui_dir/meta"
if [[ -f "$tui_meta" ]]; then
  tui_session_id="$(meta_get_test "$tui_meta" claude_session_id)"
else
  tui_session_id=""
fi
if [[ "$tui_session_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
  pass 'new TUI stores a UUIDv4 session id'
else
  fail 'new TUI stores a UUIDv4 session id' "invalid session: $tui_session_id"
fi
tui_log="$(cat "$FAKE_LOG")"
assert_contains 'new TUI invokes interactive Claude mode' "$tui_log" \
  'invocation_mode=tui'
assert_contains 'new TUI runs in selected cwd' "$tui_log" "cwd=$OTHER_PROJECT"
assert_contains 'new TUI passes its allocated session id' "$tui_log" \
  "session_id_arg=$tui_session_id"
assert_file 'TUI batch stores mode' "$tui_dir/turns/0001/mode"
assert_file 'TUI batch stores stderr' "$tui_dir/turns/0001/stderr.log"
assert_file 'TUI batch stores result' "$tui_dir/turns/0001/result.md"
assert_file 'TUI batch stores exit metadata' "$tui_dir/turns/0001/exit.meta"
if [[ ! -e "$tui_dir/turns/0001/response.json" ]]; then
  pass 'TUI batch does not fabricate a headless response'
else
  fail 'TUI batch does not fabricate a headless response' \
    'unexpected response.json'
fi

capture "$SCRIPT" send "$tui_worker_id" 'continue after interactive work'
assert_eq 'headless send resumes a TUI-created worker' '0' "$RC"
assert_contains 'headless send after TUI uses turn two' "$OUTPUT" 'TURN=2'

: >"$FAKE_LOG"
if attach_output="$(
  cd "$PROJECT"
  "$SCRIPT" tui "$tui_worker_id" 2>"$TEST_ROOT/tui-attach.err"
)"; then
  attach_rc=0
else
  attach_rc=$?
fi
assert_eq 'existing worker TUI attach succeeds' '0' "$attach_rc"
assert_contains 'TUI attach allocates the next batch' "$attach_output" 'TURN=3'
attach_log="$(cat "$FAKE_LOG")"
assert_contains 'TUI attach resumes stored session' "$attach_log" \
  "resume=$tui_session_id"
assert_contains 'TUI attach ignores caller cwd' "$attach_log" "cwd=$OTHER_PROJECT"
assert_contains 'TUI attach preserves stored model' "$attach_log" 'model=haiku'
assert_contains 'TUI attach preserves stored role prompt' "$attach_log" \
  'role_prompt=explorer'

capture "$SCRIPT" tui --model opus "$tui_worker_id"
assert_eq 'existing TUI rejects model override' '2' "$RC"
assert_contains 'TUI override error is clear' "$STDERR" \
  'creation options cannot be used'

capture "$SCRIPT" start --cwd "$PROJECT" 'missing session TUI fixture'
missing_session_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
missing_session_meta="$GLM_AGENT_HOME/workers/$missing_session_id/meta"
sed 's/^claude_session_id=.*/claude_session_id=/' "$missing_session_meta" \
  >"$missing_session_meta.next"
mv "$missing_session_meta.next" "$missing_session_meta"
capture "$SCRIPT" tui "$missing_session_id"
assert_eq 'TUI attach rejects missing stored session' '2' "$RC"
assert_contains 'missing TUI session error is clear' "$STDERR" \
  'worker has no Claude session'

capture "$SCRIPT" start --cwd "$PROJECT" 'missing cwd TUI fixture'
missing_cwd_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
missing_cwd_meta="$GLM_AGENT_HOME/workers/$missing_cwd_id/meta"
sed 's|^cwd=.*|cwd=/path/that/does/not/exist|' "$missing_cwd_meta" \
  >"$missing_cwd_meta.next"
mv "$missing_cwd_meta.next" "$missing_cwd_meta"
capture "$SCRIPT" tui "$missing_cwd_id"
assert_eq 'TUI attach rejects missing stored cwd' '2' "$RC"
assert_contains 'missing stored cwd error is clear' "$STDERR" \
  'worker working directory does not exist'

capture "$SCRIPT" start --cwd "$PROJECT" 'active TUI fixture'
active_tui_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
active_tui_dir="$GLM_AGENT_HOME/workers/$active_tui_id"
mkdir "$active_tui_dir/active"
cat >"$active_tui_dir/active/state" <<EOF
generation=active-tui-generation
mode=headless
turn=2
supervision=sync
runner_pid=$$
runner_start=$(process_start_test $$)
provider_pid=
provider_pgid=
provider_start=
started_at=$(date +%s)
EOF
capture "$SCRIPT" tui "$active_tui_id"
assert_eq 'TUI attach rejects active worker' '2' "$RC"
assert_contains 'active TUI error is clear' "$STDERR" 'worker is active'
rm -f "$active_tui_dir/active/state"
rmdir "$active_tui_dir/active"

capture "$SCRIPT" close "$tui_worker_id"
assert_eq 'TUI worker closes after exit' '0' "$RC"
capture "$SCRIPT" tui "$tui_worker_id"
assert_eq 'TUI attach rejects closed worker' '2' "$RC"
assert_contains 'closed TUI error is clear' "$STDERR" 'worker is closed'

export FAKE_TUI_BEHAVIOR=malformed
capture "$SCRIPT" tui --cwd "$PROJECT"
assert_eq 'malformed TUI result fails the batch' '1' "$RC"
assert_contains 'malformed TUI result is INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'malformed TUI result explains failure' "$OUTPUT" \
  'ERROR=result-status-invalid'
export FAKE_TUI_BEHAVIOR=missing
capture "$SCRIPT" tui --cwd "$PROJECT"
assert_eq 'missing TUI result fails the batch' '1' "$RC"
assert_contains 'missing TUI result explains failure' "$OUTPUT" \
  'ERROR=result-file-missing'
export FAKE_TUI_BEHAVIOR=fail
capture "$SCRIPT" tui --cwd "$PROJECT"
assert_eq 'nonzero TUI exit fails the batch' '1' "$RC"
assert_contains 'nonzero TUI exit is invocation failure' "$OUTPUT" \
  'ERROR=claude-exit-21'
unset FAKE_TUI_BEHAVIOR

capture "$SCRIPT" start --cwd "$PROJECT" 'stale lock recovery worker'
assert_eq 'stale lock worker starts' '0' "$RC"
stale_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
stale_dir="$GLM_AGENT_HOME/workers/$stale_worker_id"
mkdir "$stale_dir/active"
cat >"$stale_dir/active/state" <<EOF
generation=stale-generation
mode=headless
turn=2
supervision=async
runner_pid=99999999
runner_start=stale-process-start
provider_pid=
provider_pgid=
provider_start=
started_at=1
EOF
sed 's/^status=.*/status=RUNNING/; s/^turn=.*/turn=2/' \
  "$stale_dir/meta" >"$stale_dir/meta.next"
mv "$stale_dir/meta.next" "$stale_dir/meta"
capture "$SCRIPT" status "$stale_worker_id"
assert_eq 'status recovers a stale runner' '0' "$RC"
assert_contains 'stale runner becomes INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'stale runner is classified interrupted' "$OUTPUT" \
  'ERROR_KIND=interrupted'
if [[ ! -d "$stale_dir/active" ]]; then
  pass 'stale recovery releases the worker lock'
else
  fail 'stale recovery releases the worker lock' 'active directory remains'
fi

capture "$SCRIPT" start --cwd "$PROJECT" 'concurrent finalizer worker'
finalizer_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
finalizer_dir="$GLM_AGENT_HOME/workers/$finalizer_worker_id"
mkdir "$finalizer_dir/active"
cat >"$finalizer_dir/active/state" <<EOF
generation=old-finalizer-generation
mode=headless
turn=2
supervision=async
runner_pid=99999998
runner_start=stale-process-start
provider_pid=
provider_pgid=
provider_start=
started_at=1
EOF
mkdir "$finalizer_dir/active/finalizing"
cat >"$finalizer_dir/active/finalizing/owner" <<EOF
pid=99999997
start=stale-finalizer-start
EOF
sed 's/^status=.*/status=RUNNING/; s/^turn=.*/turn=2/' \
  "$finalizer_dir/meta" >"$finalizer_dir/meta.next"
mv "$finalizer_dir/meta.next" "$finalizer_dir/meta"
export FAKE_CLAUDE_BLOCK_STARTED="$TEST_ROOT/finalizer.started"
export FAKE_CLAUDE_BLOCK_RELEASE="$TEST_ROOT/finalizer.release"
"$SCRIPT" status "$finalizer_worker_id" \
  >"$TEST_ROOT/finalizer-status-one.out" 2>&1 &
finalizer_status_one_pid=$!
"$SCRIPT" status "$finalizer_worker_id" \
  >"$TEST_ROOT/finalizer-status-two.out" 2>&1 &
finalizer_status_two_pid=$!
(
  for _ in {1..500}; do
    if "$SCRIPT" send --async "$finalizer_worker_id" \
      'WAIT_FOR_RELEASE replacement generation' \
      >"$TEST_ROOT/finalizer-replacement.out" \
      2>"$TEST_ROOT/finalizer-replacement.err"; then
      exit 0
    fi
    sleep 0.01
  done
  exit 1
) &
finalizer_replacement_pid=$!
wait "$finalizer_status_one_pid" || true
wait "$finalizer_status_two_pid" || true
if wait "$finalizer_replacement_pid"; then
  pass 'replacement turn starts after concurrent stale finalizers'
else
  fail 'replacement turn starts after concurrent stale finalizers' \
    "$(cat "$TEST_ROOT/finalizer-replacement.err")"
fi
for _ in {1..500}; do
  [[ -f "$FAKE_CLAUDE_BLOCK_STARTED" ]] && break
  sleep 0.01
done
capture "$SCRIPT" status "$finalizer_worker_id"
assert_contains 'replacement generation remains active' "$OUTPUT" 'STATUS=RUNNING'
if [[ "$(sed -n 's/^generation=//p' "$finalizer_dir/active/state" 2>/dev/null)" != \
  'old-finalizer-generation' ]]; then
  pass 'stale finalizers cannot remove the replacement generation'
else
  fail 'stale finalizers cannot remove the replacement generation' \
    'old generation still owns the worker'
fi
: >"$FAKE_CLAUDE_BLOCK_RELEASE"
capture "$SCRIPT" wait --timeout 5 "$finalizer_worker_id"
assert_contains 'replacement generation reaches terminal state' "$OUTPUT" \
  'STATUS=DONE'
assert_contains 'replacement generation meta turn survives concurrent stale finalizers' \
  "$OUTPUT" 'TURN=3'
assert_file 'replacement generation turn directory is the real turn' \
  "$finalizer_dir/turns/0003/result.md"
unset FAKE_CLAUDE_BLOCK_STARTED FAKE_CLAUDE_BLOCK_RELEASE

orphan_finalize_started="$TEST_ROOT/orphan-finalize.started"
orphan_finalize_release="$TEST_ROOT/orphan-finalize.release"
orphan_finalize_child_pid_file="$TEST_ROOT/orphan-finalize.child.pid"
orphan_finalize_provider_pgid_file="$TEST_ROOT/orphan-finalize.provider.pgid"
export FAKE_CLAUDE_HANG_STARTED="$orphan_finalize_started"
export FAKE_CLAUDE_HANG_RELEASE="$orphan_finalize_release"
export FAKE_CLAUDE_CHILD_PID_FILE="$orphan_finalize_child_pid_file"
export FAKE_CLAUDE_PROVIDER_PGID_FILE="$orphan_finalize_provider_pgid_file"
capture "$SCRIPT" start --async --cwd "$PROJECT" \
  'HANG_WITH_CHILD HANG_WITH_TERM_IGNORING_CHILD orphan finalize me'
assert_eq 'orphan finalize test async worker starts' '0' "$RC"
orphan_finalize_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
orphan_finalize_dir="$GLM_AGENT_HOME/workers/$orphan_finalize_worker_id"
for _ in {1..500}; do
  [[ -f "$orphan_finalize_started" && -s "$orphan_finalize_child_pid_file" ]] && break
  sleep 0.01
done
orphan_finalize_child_pid="$(cat "$orphan_finalize_child_pid_file" 2>/dev/null || true)"
if [[ -n "$orphan_finalize_child_pid" ]] &&
  kill -0 "$orphan_finalize_child_pid" 2>/dev/null; then
  pass 'orphan finalize test provider child is running'
else
  fail 'orphan finalize test provider child is running' \
    'provider child did not start'
fi
orphan_finalize_runner_pid="$(sed -n 's/^runner_pid=//p' \
  "$orphan_finalize_dir/active/state" | head -n 1)"
kill -KILL "$orphan_finalize_runner_pid" 2>/dev/null || true
wait "$orphan_finalize_runner_pid" 2>/dev/null || true
capture "$SCRIPT" status "$orphan_finalize_worker_id"
assert_eq 'status recovers a runner killed while its provider survives' '0' "$RC"
assert_contains 'orphaned runner becomes INVALID' "$OUTPUT" 'STATUS=INVALID'
for _ in {1..300}; do
  if ! process_is_running_test "$orphan_finalize_child_pid"; then
    break
  fi
  sleep 0.01
done
if ! process_is_running_test "$orphan_finalize_child_pid"; then
  pass 'finalizing a runner killed out from under its provider still drains it'
else
  fail 'finalizing a runner killed out from under its provider still drains it' \
    "child $orphan_finalize_child_pid is still alive"
fi
unset FAKE_CLAUDE_HANG_STARTED FAKE_CLAUDE_HANG_RELEASE \
  FAKE_CLAUDE_CHILD_PID_FILE FAKE_CLAUDE_PROVIDER_PGID_FILE

capture "$SCRIPT" start --cwd "$PROJECT" 'empty runner recovery worker'
empty_runner_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
empty_runner_dir="$GLM_AGENT_HOME/workers/$empty_runner_id"
mkdir "$empty_runner_dir/active"
cat >"$empty_runner_dir/active/state" <<EOF
generation=empty-runner-generation
mode=headless
turn=2
supervision=async
runner_pid=
runner_start=
provider_pid=
provider_pgid=
provider_start=
started_at=1
EOF
capture "$SCRIPT" status "$empty_runner_id"
assert_contains 'stale empty runner becomes INVALID' "$OUTPUT" 'STATUS=INVALID'
if [[ ! -d "$empty_runner_dir/active" ]]; then
  pass 'stale empty runner lock is recoverable'
else
  fail 'stale empty runner lock is recoverable' 'active directory remains'
fi

capture "$SCRIPT" start --cwd "$PROJECT" 'reused runner recovery worker'
reused_runner_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
reused_runner_dir="$GLM_AGENT_HOME/workers/$reused_runner_id"
mkdir "$reused_runner_dir/active"
cat >"$reused_runner_dir/active/state" <<EOF
generation=reused-runner-generation
mode=headless
turn=2
supervision=sync
runner_pid=$$
runner_start=not-the-current-process-start
provider_pid=
provider_pgid=
provider_start=
started_at=1
EOF
capture "$SCRIPT" status "$reused_runner_id"
assert_contains 'reused runner PID becomes INVALID' "$OUTPUT" 'STATUS=INVALID'

capture "$SCRIPT" start --cwd "$PROJECT" 'active status authority worker'
active_status_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
active_status_dir="$GLM_AGENT_HOME/workers/$active_status_id"
mkdir "$active_status_dir/active"
cat >"$active_status_dir/active/state" <<EOF
generation=active-status-generation
mode=headless
turn=2
supervision=sync
runner_pid=$$
runner_start=$(process_start_test $$)
provider_pid=
provider_pgid=
provider_start=
started_at=$(date +%s)
EOF
capture "$SCRIPT" status "$active_status_id"
assert_contains 'live active lock is authoritative RUNNING state' "$OUTPUT" \
  'STATUS=RUNNING'
rm -f "$active_status_dir/active/state"
rmdir "$active_status_dir/active"

SLOW_CAT_DIR="$TEST_ROOT/slow-cat"
mkdir -p "$SLOW_CAT_DIR"
cat >"$SLOW_CAT_DIR/cat" <<'SLOWCAT'
#!/usr/bin/env bash
if [[ -n "${SLOW_CAT_ACTIVE_STATE:-}" && "$1" == *"/active/state" ]]; then
  sleep 0.3
fi
exec /bin/cat "$@"
SLOWCAT
chmod +x "$SLOW_CAT_DIR/cat"

capture "$SCRIPT" start --cwd "$PROJECT" 'concurrent release race worker'
race_release_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
race_release_dir="$GLM_AGENT_HOME/workers/$race_release_id"
mkdir "$race_release_dir/active"
cat >"$race_release_dir/active/state" <<EOF
generation=race-release-generation
mode=headless
turn=2
supervision=sync
runner_pid=$$
runner_start=$(process_start_test $$)
provider_pid=
provider_pgid=
provider_start=
started_at=$(date +%s)
EOF
(
  sleep 0.1
  rm -f "$race_release_dir/active/state"
  rmdir "$race_release_dir/active" 2>/dev/null || true
) &
race_release_pid=$!
if OUTPUT="$(SLOW_CAT_ACTIVE_STATE=1 PATH="$SLOW_CAT_DIR:$PATH" \
  "$SCRIPT" status "$race_release_id" 2>"$TEST_ROOT/race-release.err")"; then
  RC=0
else
  RC=$?
fi
wait "$race_release_pid" 2>/dev/null || true
assert_eq 'status does not crash when active/state vanishes mid-read' '0' "$RC"
assert_contains 'status still prints a stable snapshot after the vanish race' \
  "$OUTPUT" 'WORKER_ID='
assert_not_contains 'status does not leak a raw cat crash to stderr' \
  "$(cat "$TEST_ROOT/race-release.err")" 'No such file or directory'
rm -f "$race_release_dir/active/state"
rmdir "$race_release_dir/active" 2>/dev/null || true

capture "$SCRIPT" start --cwd "$PROJECT" 'partial active publication worker'
partial_active_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
partial_active_dir="$GLM_AGENT_HOME/workers/$partial_active_id"
sed 's/^status=.*/status=RUNNING/; s/^turn=.*/turn=2/' \
  "$partial_active_dir/meta" >"$partial_active_dir/meta.next"
mv "$partial_active_dir/meta.next" "$partial_active_dir/meta"
mkdir "$partial_active_dir/active"
"$SCRIPT" status "$partial_active_id" \
  >"$TEST_ROOT/partial-active.out" 2>"$TEST_ROOT/partial-active.err" &
partial_status_pid=$!
sleep 0.05
cat >"$partial_active_dir/active/state" <<EOF
generation=partial-active-generation
mode=headless
turn=2
supervision=sync
runner_pid=$$
runner_start=$(process_start_test $$)
provider_pid=
provider_pgid=
provider_start=
started_at=$(date +%s)
EOF
if wait "$partial_status_pid"; then
  partial_status_output="$(cat "$TEST_ROOT/partial-active.out")"
  assert_contains 'status retries partial active publication' \
    "$partial_status_output" 'STATUS=RUNNING'
  assert_contains 'partial active publication keeps active turn' \
    "$partial_status_output" 'ACTIVE_TURN=2'
else
  fail 'status retries partial active publication' \
    "$(cat "$TEST_ROOT/partial-active.err")"
fi
rm -f "$partial_active_dir/active/state"
rmdir "$partial_active_dir/active"

capture "$SCRIPT" start --cwd "$PROJECT" 'permanently missing active state worker'
missing_state_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
missing_state_dir="$GLM_AGENT_HOME/workers/$missing_state_id"
sed 's/^status=.*/status=RUNNING/; s/^turn=.*/turn=2/' \
  "$missing_state_dir/meta" >"$missing_state_dir/meta.next"
mv "$missing_state_dir/meta.next" "$missing_state_dir/meta"
mkdir "$missing_state_dir/active"
missing_state_started_at="$(date +%s)"
if missing_state_wait_output="$(gtimeout 6 "$SCRIPT" wait --timeout 1 \
  "$missing_state_id" 2>&1)"; then
  missing_state_wait_rc=0
else
  missing_state_wait_rc=$?
fi
missing_state_elapsed="$(( $(date +%s) - missing_state_started_at ))"
assert_eq 'wait honors timeout when active/state never appears' '0' \
  "$missing_state_wait_rc"
assert_contains 'wait times out instead of hanging on missing active/state' \
  "$missing_state_wait_output" 'WAIT_RESULT=TIMEOUT'
if ((missing_state_elapsed <= 3)); then
  pass 'wait with missing active/state returns near the requested timeout'
else
  fail 'wait with missing active/state returns near the requested timeout' \
    "took ${missing_state_elapsed}s for a 1s timeout"
fi

touch -mt "$(date -v-10S +%Y%m%d%H%M.%S)" "$missing_state_dir/active"
capture "$SCRIPT" status "$missing_state_id"
assert_eq 'status recovers an orphaned lock with no active/state' '0' "$RC"
assert_contains 'orphaned lock with no active/state becomes INVALID' "$OUTPUT" \
  'STATUS=INVALID'
assert_contains 'orphaned lock with no active/state is classified interrupted' \
  "$OUTPUT" 'ERROR_KIND=interrupted'
if [[ ! -d "$missing_state_dir/active" ]]; then
  pass 'orphaned lock with no active/state is released'
else
  fail 'orphaned lock with no active/state is released' 'active directory remains'
fi

FAKE_GNU_STAT_DIR="$TEST_ROOT/fake-gnu-stat"
mkdir -p "$FAKE_GNU_STAT_DIR"
cat >"$FAKE_GNU_STAT_DIR/stat" <<'FAKESTAT'
#!/usr/bin/env bash
mode="$1"
path="$3"
case "$mode" in
  -f)
    printf 'Filesystem Type: fake-gnu-confusion\n'
    exit 1
    ;;
  -c)
    /usr/bin/stat -f '%m' "$path" 2>/dev/null
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
FAKESTAT
chmod +x "$FAKE_GNU_STAT_DIR/stat"

capture "$SCRIPT" start --cwd "$PROJECT" 'gnu stat fallback worker'
gnu_stat_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
gnu_stat_dir="$GLM_AGENT_HOME/workers/$gnu_stat_worker_id"
sed 's/^status=.*/status=RUNNING/; s/^turn=.*/turn=2/' \
  "$gnu_stat_dir/meta" >"$gnu_stat_dir/meta.next"
mv "$gnu_stat_dir/meta.next" "$gnu_stat_dir/meta"
mkdir "$gnu_stat_dir/active"
touch -mt "$(date -v-10S +%Y%m%d%H%M.%S)" "$gnu_stat_dir/active"
if OUTPUT="$(PATH="$FAKE_GNU_STAT_DIR:$PATH" "$SCRIPT" status \
  "$gnu_stat_worker_id" 2>"$TEST_ROOT/gnu-stat.err")"; then
  RC=0
else
  RC=$?
fi
assert_eq 'status succeeds when BSD stat -f is unavailable' '0' "$RC"
assert_contains 'GNU stat -c fallback recovers an aged orphan lock' "$OUTPUT" \
  'STATUS=INVALID'
if [[ ! -d "$gnu_stat_dir/active" ]]; then
  pass 'GNU stat -c fallback path releases the lock'
else
  fail 'GNU stat -c fallback path releases the lock' \
    "$(cat "$TEST_ROOT/gnu-stat.err")"
fi

capture "$SCRIPT" wait --timeout -1 "$async_worker_id"
assert_eq 'negative wait timeout is rejected' '2' "$RC"
capture "$SCRIPT" wait --timeout 301 "$async_worker_id"
assert_eq 'wait timeout above maximum is rejected' '2' "$RC"
capture "$SCRIPT" wait --timeout nope "$async_worker_id"
assert_eq 'non-numeric wait timeout is rejected' '2' "$RC"

for code in 1113 1308 1310 1316 1317 1318 1319 1320 1321; do
  capture "$SCRIPT" send "$worker_id" "ZAI_ERROR_$code"
  assert_eq "quota code $code fails the turn" '1' "$RC"
  assert_contains "quota code $code is classified" "$OUTPUT" \
    'ERROR_KIND=quota-exhausted'
  assert_contains "quota code $code is retained" "$OUTPUT" \
    "PROVIDER_CODE=$code"
  assert_contains "quota code $code recommends fallback" "$OUTPUT" \
    'FALLBACK_RECOMMENDED=true'
  assert_not_contains "quota code $code stdout hides secret" "$OUTPUT" "$secret"
  assert_not_contains "quota code $code stdout hides session" "$OUTPUT" 'session-1'
  assert_not_contains "quota code $code stderr hides secret" "$STDERR" "$secret"
  assert_not_contains "quota code $code stderr hides session" "$STDERR" 'session-1'
done

for code_and_kind in \
  '1302 provider-transient' \
  '1305 provider-transient' \
  '1000 authentication' \
  '1001 authentication' \
  '1003 authentication' \
  '1211 model-unavailable' \
  '1311 model-unavailable'; do
  provider_test_code="${code_and_kind%% *}"
  provider_test_kind="${code_and_kind#* }"
  capture "$SCRIPT" send "$worker_id" "ZAI_ERROR_$provider_test_code"
  assert_eq "provider code $provider_test_code fails the turn" '1' "$RC"
  assert_contains "provider code $provider_test_code kind" "$OUTPUT" \
    "ERROR_KIND=$provider_test_kind"
  assert_contains "provider code $provider_test_code is retained" "$OUTPUT" \
    "PROVIDER_CODE=$provider_test_code"
  assert_contains "provider code $provider_test_code does not fallback" "$OUTPUT" \
    'FALLBACK_RECOMMENDED=false'
done

capture "$SCRIPT" start --role general-purpose --cwd "$PROJECT" \
  'successful control fields'
assert_eq 'successful control fields turn succeeds' '0' "$RC"
assert_contains 'success has empty error kind' "$OUTPUT" $'ERROR_KIND=\n'
assert_contains 'success has empty provider code' "$OUTPUT" $'PROVIDER_CODE=\n'
assert_contains 'success does not recommend fallback' "$OUTPUT" \
  'FALLBACK_RECOMMENDED=false'

: >"$FAKE_LOG"
capture "$SCRIPT" start --role explorer --model haiku --cwd "$OTHER_PROJECT" \
  'inspect the repository without changing it'
assert_eq 'explorer start succeeds' '0' "$RC"
explorer_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
assert_contains 'explorer start reports role' "$OUTPUT" 'ROLE=explorer'
assert_contains 'explorer start reports model' "$OUTPUT" 'MODEL=haiku'
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
assert_contains 'explorer send reports stored model' "$OUTPUT" 'MODEL=haiku'
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
assert_contains 'protocol errors are classified' "$OUTPUT" \
  'ERROR_KIND=worker-protocol'
assert_contains 'protocol errors do not fallback' "$OUTPUT" \
  'FALLBACK_RECOMMENDED=false'
missing_result_turn="$(meta_get_test "$meta" turn)"
if [[ "$missing_result_turn" =~ ^[0-9]+$ ]]; then
  pass 'invalid turn is retained in history'
else
  fail 'invalid turn is retained in history' "invalid turn: $missing_result_turn"
fi
assert_eq 'invalid turn updates worker status' 'INVALID' "$(meta_get_test "$meta" status)"
assert_eq 'invalid turn keeps prior canonical result' "$send_result" "$($SCRIPT result "$worker_id")"

capture "$SCRIPT" send "$worker_id" 'MALFORMED_RESULT'
assert_eq 'malformed result status is a protocol failure' '1' "$RC"
assert_contains 'malformed result reports INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'malformed result identifies status error' "$OUTPUT" 'ERROR=result-status-invalid'
malformed_result_turn="$(meta_get_test "$meta" turn)"
assert_eq 'malformed result turn follows missing result' \
  "$((10#$missing_result_turn + 1))" "$malformed_result_turn"

capture "$SCRIPT" send "$worker_id" 'CLAUDE_FAIL'
assert_eq 'nonzero Claude exit is an invocation failure' '1' "$RC"
assert_contains 'nonzero Claude exit reports INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'nonzero Claude exit code is retained' "$OUTPUT" 'ERROR=claude-exit-17'
claude_fail_turn="$(meta_get_test "$meta" turn)"
printf -v claude_fail_label '%04d' "$claude_fail_turn"
assert_contains 'nonzero Claude stderr is preserved' \
  "$(cat "$GLM_AGENT_HOME/workers/$worker_id/turns/$claude_fail_label/stderr.log")" \
  'simulated claude failure'

capture "$SCRIPT" send "$worker_id" 'BAD_JSON'
assert_eq 'malformed Claude JSON is an invocation failure' '1' "$RC"
assert_contains 'malformed Claude JSON reports INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'malformed Claude JSON identifies response error' "$OUTPUT" 'ERROR=invalid-response'
bad_json_turn="$(meta_get_test "$meta" turn)"
printf -v bad_json_label '%04d' "$bad_json_turn"
assert_eq 'malformed Claude JSON raw response is preserved' 'not-json' \
  "$(cat "$GLM_AGENT_HOME/workers/$worker_id/turns/$bad_json_label/response.json")"

capture "$SCRIPT" send "$worker_id" 'WRONG_SESSION'
assert_eq 'unexpected resumed session is an invocation failure' '1' "$RC"
assert_contains 'unexpected resumed session reports INVALID' "$OUTPUT" 'STATUS=INVALID'
assert_contains 'unexpected resumed session identifies mismatch' "$OUTPUT" 'ERROR=unexpected-session-id'
assert_eq 'unexpected session does not replace stored session' 'session-1' "$(meta_get_test "$meta" claude_session_id)"

capture "$SCRIPT" start --cwd "$PROJECT" 'close race fixture worker'
assert_eq 'close race fixture starts' '0' "$RC"
close_race_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
close_race_dir="$GLM_AGENT_HOME/workers/$close_race_id"
assert_contains 'close race fixture reaches DONE before the race' "$OUTPUT" \
  'STATUS=DONE'
mkdir "$close_race_dir/active"
cat >"$close_race_dir/active/state" <<EOF
generation=close-race-generation
mode=close
turn=1
supervision=
runner_pid=
runner_start=
provider_pid=
provider_pgid=
provider_start=
started_at=1
EOF
capture "$SCRIPT" status "$close_race_id"
assert_eq 'status recovers a killed close lock' '0' "$RC"
assert_contains 'killed close lock does not corrupt a DONE worker' "$OUTPUT" \
  'STATUS=DONE'
assert_not_contains 'killed close lock does not mark the worker interrupted' \
  "$OUTPUT" 'ERROR_KIND=interrupted'
assert_contains 'killed close lock leaves closed unset' "$OUTPUT" 'CLOSED=false'
if [[ ! -d "$close_race_dir/active" ]]; then
  pass 'killed close lock is released'
else
  fail 'killed close lock is released' 'active directory remains'
fi

capture "$SCRIPT" start --cwd "$PROJECT" 'atomic active state worker'
assert_eq 'atomic active state worker starts' '0' "$RC"
atomic_state_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
atomic_state_dir="$GLM_AGENT_HOME/workers/$atomic_state_id"
atomic_state_observed_empty=0
for _ in {1..40}; do
  "$SCRIPT" close "$atomic_state_id" >/dev/null 2>&1 &
  atomic_close_pid=$!
  # Poll for the process's entire lifetime (not a fixed iteration budget):
  # the interesting window is wherever it falls inside close's execution,
  # and a fixed head-start can finish checking before that window opens.
  # Use a single read (wc -c) rather than separate -f/-s tests: two
  # independent stat() calls have their own TOCTOU gap, so a legitimate
  # release() deleting the file between them would make -s report false
  # (file gone) and be misread as "exists with zero bytes".
  while kill -0 "$atomic_close_pid" 2>/dev/null; do
    atomic_state_size="$(wc -c "$atomic_state_dir/active/state" 2>/dev/null |
      awk '{print $1}')" || atomic_state_size=""
    if [[ "$atomic_state_size" == "0" ]]; then
      atomic_state_observed_empty=1
      break
    fi
  done
  wait "$atomic_close_pid" 2>/dev/null || true
  ((atomic_state_observed_empty)) && break
done
if ((atomic_state_observed_empty)); then
  fail 'active/state is never observed empty while a lock is being acquired' \
    'observed a transient empty active/state file'
else
  pass 'active/state is never observed empty while a lock is being acquired'
fi

capture "$SCRIPT" close "$worker_id"
assert_eq 'close succeeds' '0' "$RC"
assert_contains 'close reports closed state' "$OUTPUT" 'CLOSED=true'
assert_eq 'close is persisted' 'true' "$(meta_get_test "$meta" closed)"
assert_file 'close preserves first response' "$GLM_AGENT_HOME/workers/$worker_id/turns/0001/response.json"
latest_turn="$(meta_get_test "$meta" turn)"
printf -v latest_turn_label '%04d' "$latest_turn"
assert_file 'close preserves latest prompt' \
  "$GLM_AGENT_HOME/workers/$worker_id/turns/$latest_turn_label/prompt.md"

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

# --- quota: fake curl, fixtures, and helpers --------------------------------
QUOTA_KEY='zk-quota-test-0123456789abcdef'
QUOTA_HOME="$TEST_ROOT/quota-home"
QUOTA_FIXTURES="$TEST_ROOT/quota-fixtures"
FAKE_CURL_LOG="$TEST_ROOT/curl.argv"
FAKE_CURL_STDIN="$TEST_ROOT/curl.stdin"
QUOTA_SEEN=''
mkdir -p "$QUOTA_FIXTURES"

cat >"$FAKE_BIN/curl" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail

# Fake curl for glm-agent quota tests: no network access, no real key.
# It accepts exactly the flags glm-agent quota uses and rejects anything else.
log="${FAKE_CURL_LOG:?}"
: >>"$log"
for arg in "$@"; do
  printf 'arg=%s\n' "$arg" >>"$log"
done

# -q only disables the user's curlrc when it is the very first argument, so
# it is accepted here and nowhere else.
if [[ "${1:-}" == -q ]]; then
  shift
fi

output=''
write_out=''
url=''
silent=0
stdin_header=0
language_header=0
while (($# > 0)); do
  case "$1" in
    -sS) silent=1; shift ;;
    --connect-timeout|--max-time) shift 2 ;;
    -H)
      case "$2" in
        @-) stdin_header=1 ;;
        'Accept-Language: en-US,en') language_header=1 ;;
        *) printf 'fake curl: unexpected header\n' >&2; exit 99 ;;
      esac
      shift 2
      ;;
    -o) output="$2"; shift 2 ;;
    -w) write_out="$2"; shift 2 ;;
    -*) printf 'fake curl: unexpected option: %s\n' "$1" >&2; exit 99 ;;
    *) url="$1"; shift ;;
  esac
done

if ((silent != 1 || stdin_header != 1 || language_header != 1)) ||
  [[ -z "$output" || -z "$url" || "$write_out" != '%{http_code}' ]]; then
  printf 'fake curl: incomplete invocation\n' >&2
  exit 99
fi

cat >"${FAKE_CURL_STDIN:?}"

if [[ -n "${FAKE_CURL_BLOCK_STARTED:-}" ]]; then
  : >"$FAKE_CURL_BLOCK_STARTED"
  for _ in {1..500}; do
    [[ -f "${FAKE_CURL_BLOCK_RELEASE:?}" ]] && break
    sleep 0.01
  done
fi

# A non-zero exit can still follow a received status and body (a timeout while
# reading the response, for example), so the body and status are written first.
if [[ -n "${FAKE_CURL_BODY_FILE:-}" ]]; then
  cp "$FAKE_CURL_BODY_FILE" "$output"
fi
printf '%s' "${FAKE_CURL_STATUS:-200}"

curl_exit="${FAKE_CURL_EXIT:-0}"
if ((curl_exit != 0)); then
  printf 'curl: (%s) fake failure\n' "$curl_exit" >&2
  exit "$curl_exit"
fi
FAKE
chmod +x "$FAKE_BIN/curl"

cat >"$QUOTA_FIXTURES/ok.json" <<'JSON'
{"code":200,"msg":"Operation successful","data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":1450,"remaining":549,"percentage":72,"nextResetTime":1790791395020},{"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":7974,"remaining":2025,"percentage":79,"nextResetTime":1791162764983}],"level":"lite"},"success":true}
JSON
jq '.data.limits[0].remaining = 0' "$QUOTA_FIXTURES/ok.json" \
  >"$QUOTA_FIXTURES/zero.json"
jq '.data.limits += [{"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":20,"remaining":980,"percentage":2,"nextResetTime":1793000000000}]' \
  "$QUOTA_FIXTURES/ok.json" >"$QUOTA_FIXTURES/time-limit.json"
jq '.data.limits[0].unit = 9 | .data.limits[0].number = 2' \
  "$QUOTA_FIXTURES/ok.json" >"$QUOTA_FIXTURES/unknown-window.json"
jq '.data.limits = []' "$QUOTA_FIXTURES/ok.json" \
  >"$QUOTA_FIXTURES/empty-limits.json"
jq 'del(.data.limits[0].remaining, .data.limits[0].nextResetTime) | .data.level = null' \
  "$QUOTA_FIXTURES/ok.json" >"$QUOTA_FIXTURES/sparse.json"
jq '.data.level = "li\nQUOTA_STATUS=FORGED"' "$QUOTA_FIXTURES/ok.json" \
  >"$QUOTA_FIXTURES/control-chars.json"

# quota_record: remember what the last run printed so the key scans can prove
# the API key never reached stdout or stderr. Every quota run must call it.
quota_record() {
  QUOTA_SEEN+="$OUTPUT"$'\n'"$STDERR"$'\n'
}

# quota_case <http-status> <body-file-or-empty> <curl-exit> [VAR=value ...]
# Runs "glm-agent quota" against the fake curl and records the run.
quota_case() {
  local status="$1" body="$2" curl_exit="$3"
  shift 3
  : >"$FAKE_CURL_LOG"
  : >"$FAKE_CURL_STDIN"
  capture env -u ZAI_BASE_URL ZAI_API_KEY="$QUOTA_KEY" \
    GLM_AGENT_HOME="$QUOTA_HOME" FAKE_CURL_STATUS="$status" \
    FAKE_CURL_BODY_FILE="$body" FAKE_CURL_EXIT="$curl_exit" \
    FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_CURL_STDIN="$FAKE_CURL_STDIN" \
    "$@" "$SCRIPT" quota
  quota_record
}

# make_quota_bin <dir> <tool-to-omit>: a PATH holding only what quota needs.
make_quota_bin() {
  local dir="$1" omit="$2" tool
  mkdir -p "$dir"
  for tool in dirname mkdir chmod mktemp mv cat jq curl; do
    if [[ "$tool" != "$omit" ]]; then
      ln -sf "$(command -v "$tool")" "$dir/$tool"
    fi
  done
}

# --- quota: probe response, request shape, raw artifacts ---------------------
expected_quota_ok="$(cat <<EOF
QUOTA_STATUS=OK
PLAN_LEVEL=lite
LIMIT_COUNT=2
LIMIT_1_TYPE=CREDIT_LIMIT
LIMIT_1_WINDOW=5h
LIMIT_1_TOTAL=2000
LIMIT_1_USED=1450
LIMIT_1_REMAINING=549
LIMIT_1_USED_PERCENT=72
LIMIT_1_RESET_AT=2026-09-30T18:03:15Z
LIMIT_2_TYPE=CREDIT_LIMIT
LIMIT_2_WINDOW=1w
LIMIT_2_TOTAL=10000
LIMIT_2_USED=7974
LIMIT_2_REMAINING=2025
LIMIT_2_USED_PERCENT=79
LIMIT_2_RESET_AT=2026-10-05T01:12:44Z
RESPONSE=$QUOTA_HOME/quota/response.json
ERROR_KIND=
PROVIDER_CODE=
EOF
)"

quota_case 200 "$QUOTA_FIXTURES/ok.json" 0
assert_eq 'quota succeeds on the probe response' '0' "$RC"
assert_eq 'quota prints the documented fields' "$expected_quota_ok" "$OUTPUT"
assert_eq 'quota stderr is empty on success' '' "$STDERR"

quota_argv="$(cat "$FAKE_CURL_LOG")"
assert_eq 'quota disables curlrc with -q as the first curl argument' \
  'arg=-q' "$(head -n 1 "$FAKE_CURL_LOG")"
assert_contains 'quota runs curl silently with errors' "$quota_argv" $'arg=-sS\n'
assert_contains 'quota bounds connect and total time' "$quota_argv" \
  $'arg=--connect-timeout\narg=5\narg=--max-time\narg=10\n'
assert_contains 'quota reads the auth header from stdin' "$quota_argv" \
  $'arg=-H\narg=@-\n'
assert_contains 'quota asks for English messages' "$quota_argv" \
  $'arg=-H\narg=Accept-Language: en-US,en\n'
assert_contains 'quota prints only the HTTP status on curl stdout' \
  "$quota_argv" $'arg=-w\narg=%{http_code}\n'
assert_contains 'quota writes the body inside its own state directory' \
  "$quota_argv" $'arg=-o\narg='"$QUOTA_HOME/quota/.response."
assert_eq 'quota targets the monitor endpoint' \
  'arg=https://api.z.ai/api/monitor/usage/quota/limit' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"
assert_not_contains 'quota keeps the API key out of curl argv' \
  "$quota_argv" "$QUOTA_KEY"
assert_eq 'quota sends the key only as one stdin header line' \
  "Authorization: $QUOTA_KEY" "$(cat "$FAKE_CURL_STDIN")"

assert_eq 'quota keeps exactly the two raw artifacts' \
  $'response.json\nstderr.log' "$(ls -A "$QUOTA_HOME/quota")"
assert_eq 'quota stores the raw response body' \
  "$(cat "$QUOTA_FIXTURES/ok.json")" "$(cat "$QUOTA_HOME/quota/response.json")"
assert_eq 'quota state home stays private' '700' "$(file_mode "$QUOTA_HOME")"
assert_eq 'quota directory is private' '700' "$(file_mode "$QUOTA_HOME/quota")"
assert_eq 'quota response file is private' '600' \
  "$(file_mode "$QUOTA_HOME/quota/response.json")"

quota_case 200 "$QUOTA_FIXTURES/zero.json" 0
assert_eq 'quota overwrites the raw response on each call' \
  "$(cat "$QUOTA_FIXTURES/zero.json")" "$(cat "$QUOTA_HOME/quota/response.json")"

# --- quota: field mapping ----------------------------------------------------
assert_eq 'exhausted window is still a successful lookup' '0' "$RC"
assert_contains 'quota reports a zero remainder as 0' "$OUTPUT" \
  $'LIMIT_1_REMAINING=0\n'

quota_case 200 "$QUOTA_FIXTURES/time-limit.json" 0
assert_eq 'TIME_LIMIT entry keeps the lookup successful' '0' "$RC"
assert_contains 'quota counts every limit entry' "$OUTPUT" $'LIMIT_COUNT=3\n'
assert_contains 'quota prints the third entry type verbatim' "$OUTPUT" \
  $'LIMIT_3_TYPE=TIME_LIMIT\n'
assert_contains 'quota prints the third entry reset in UTC' "$OUTPUT" \
  $'LIMIT_3_RESET_AT=2026-10-26T07:33:20Z\n'

quota_case 200 "$QUOTA_FIXTURES/unknown-window.json" 0
assert_contains 'unknown unit keeps its code and number' "$OUTPUT" \
  $'LIMIT_1_WINDOW=u9x2\n'

quota_case 200 "$QUOTA_FIXTURES/empty-limits.json" 0
assert_eq 'empty limits list is still a successful lookup' '0' "$RC"
assert_contains 'empty limits list reports LIMIT_COUNT=0' "$OUTPUT" \
  $'LIMIT_COUNT=0\n'
assert_not_contains 'empty limits list prints no limit lines' "$OUTPUT" \
  'LIMIT_1_'

quota_case 200 "$QUOTA_FIXTURES/sparse.json" 0
assert_eq 'limit missing remaining and reset time is still successful' '0' "$RC"
assert_contains 'missing remaining prints an empty value' "$OUTPUT" \
  $'LIMIT_1_REMAINING=\n'
assert_contains 'missing reset time prints an empty value' "$OUTPUT" \
  $'LIMIT_1_RESET_AT=\nLIMIT_2_TYPE='
assert_contains 'null plan level prints an empty value' "$OUTPUT" \
  $'PLAN_LEVEL=\n'
assert_not_contains 'null and missing fields never print the word null' \
  "$OUTPUT" 'null'

quota_case 200 "$QUOTA_FIXTURES/control-chars.json" 0
assert_contains 'server control characters cannot start a new output line' \
  "$OUTPUT" $'PLAN_LEVEL=li QUOTA_STATUS=FORGED\n'
assert_eq 'exactly one QUOTA_STATUS line is printed' '1' \
  "$(printf '%s\n' "$OUTPUT" | grep -c '^QUOTA_STATUS=')"

# --- quota: endpoint follows ZAI_BASE_URL host and port ----------------------
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 \
  ZAI_BASE_URL=https://example.test:8443/api/anthropic
assert_eq 'quota keeps scheme host and port and drops the base path' \
  'arg=https://example.test:8443/api/monitor/usage/quota/limit' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"

quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 ZAI_BASE_URL=http://127.0.0.1:9000
assert_eq 'quota accepts a base URL with a port and no path' \
  'arg=http://127.0.0.1:9000/api/monitor/usage/quota/limit' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"

# --- quota: usage and configuration errors (exit 2, empty stdout) ------------
capture env ZAI_API_KEY="$QUOTA_KEY" GLM_AGENT_HOME="$QUOTA_HOME" \
  "$SCRIPT" quota extra
quota_record
assert_eq 'quota rejects extra arguments' '2|' "$RC|$OUTPUT"
assert_contains 'quota argument error is clear' "$STDERR" \
  'quota does not accept arguments'

for bad_key in "$QUOTA_KEY"$'\rtail' "$QUOTA_KEY"$'\ntail'; do
  quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 ZAI_API_KEY="$bad_key"
  assert_eq 'multi-line API key is rejected before curl runs' \
    '2||' "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
  assert_contains 'multi-line API key error names the problem' "$STDERR" \
    'API key must be a single line'
done

for bad_url in 'ftp://example.test' 'example.test/x' \
  'https://user@example.test/x' 'https://example.test:8a/x' \
  'https://example.test?x=1'; do
  quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 ZAI_BASE_URL="$bad_url"
  assert_eq "ZAI_BASE_URL [$bad_url] is rejected before curl runs" \
    '2||' "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
done

nokey_home="$TEST_ROOT/quota-nokey-home"
capture env -u ZAI_API_KEY GLM_AGENT_HOME="$nokey_home" "$SCRIPT" quota
quota_record
assert_eq 'quota without a key is a configuration error' '2|' "$RC|$OUTPUT"
assert_contains 'quota key error gives the setup instruction' "$STDERR" \
  'Run: glm-agent api-key'
if [[ ! -e "$nokey_home" ]]; then
  pass 'quota without a key creates no state'
else
  fail 'quota without a key creates no state' "unexpected path: $nokey_home"
fi

emptykey_home="$TEST_ROOT/quota-emptykey-home"
mkdir -p "$emptykey_home"
: >"$emptykey_home/.env.auth"
capture env -u ZAI_API_KEY GLM_AGENT_HOME="$emptykey_home" "$SCRIPT" quota
quota_record
assert_eq 'quota with an empty stored key is a configuration error' \
  '2|' "$RC|$OUTPUT"
assert_contains 'quota empty key error is clear' "$STDERR" \
  'stored API key is empty'

make_quota_bin "$TEST_ROOT/quota-bin-no-curl" curl
capture env PATH="$TEST_ROOT/quota-bin-no-curl" ZAI_API_KEY="$QUOTA_KEY" \
  GLM_AGENT_HOME="$QUOTA_HOME" "$BASH" "$SCRIPT" quota
quota_record
assert_eq 'quota without curl is a dependency error' '2|' "$RC|$OUTPUT"
assert_contains 'quota names the missing curl' "$STDERR" \
  'required command not found: curl'

make_quota_bin "$TEST_ROOT/quota-bin-no-jq" jq
capture env PATH="$TEST_ROOT/quota-bin-no-jq" ZAI_API_KEY="$QUOTA_KEY" \
  GLM_AGENT_HOME="$QUOTA_HOME" "$BASH" "$SCRIPT" quota
quota_record
assert_eq 'quota without jq is a dependency error' '2|' "$RC|$OUTPUT"
assert_contains 'quota names the missing jq' "$STDERR" \
  'required command not found: jq'

# --- quota: state and temp-file failures are setup errors (exit 2) ------------
# No exit path may end with status 1 and no QUOTA_STATUS line.
quota_ro_parent="$TEST_ROOT/quota-ro"
quota_ro_home="$quota_ro_parent/home"
mkdir -p "$quota_ro_parent"
chmod 500 "$quota_ro_parent"
if [[ "$(id -u)" == 0 ]]; then
  pass 'quota unwritable state home (skipped: root ignores directory modes)'
  pass 'quota names the unwritable state home (skipped: root)'
else
  quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 GLM_AGENT_HOME="$quota_ro_home"
  assert_eq 'quota with an unwritable state home is a setup error' \
    '2||' "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
  assert_contains 'quota names the unwritable state home' "$STDERR" \
    "$quota_ro_home"
fi
chmod 700 "$quota_ro_parent"

quota_blocked_home="$TEST_ROOT/quota-blocked-home"
mkdir -p "$quota_blocked_home"
: >"$quota_blocked_home/quota"
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 GLM_AGENT_HOME="$quota_blocked_home"
assert_eq 'quota with a file in place of its directory is a setup error' \
  '2||' "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
assert_contains 'quota names the blocked quota directory' "$STDERR" \
  "$quota_blocked_home/quota"

quota_unreadable_home="$TEST_ROOT/quota-unreadable-key-home"
mkdir -p "$quota_unreadable_home"
printf '%s' "$QUOTA_KEY" >"$quota_unreadable_home/.env.auth"
chmod 000 "$quota_unreadable_home/.env.auth"
if [[ "$(id -u)" == 0 ]]; then
  pass 'quota unreadable key file (skipped: root ignores file modes)'
  pass 'quota names the unreadable key file (skipped: root)'
else
  capture env -u ZAI_API_KEY GLM_AGENT_HOME="$quota_unreadable_home" \
    "$SCRIPT" quota
  quota_record
  assert_eq 'quota with an unreadable key file is a setup error' \
    '2|' "$RC|$OUTPUT"
  assert_contains 'quota names the unreadable key file' "$STDERR" \
    "$quota_unreadable_home/.env.auth"
fi
chmod 600 "$quota_unreadable_home/.env.auth"

# A fake mktemp that fails only for the second temp file, a fake mv that
# always fails, and a fake jq that fails on one chosen call.
quota_real_mktemp="$(command -v mktemp)"
quota_real_jq="$(command -v jq)"
quota_mktemp_bin="$TEST_ROOT/quota-bin-mktemp-fails"
quota_mv_bin="$TEST_ROOT/quota-bin-mv-fails"
quota_jq_bin="$TEST_ROOT/quota-bin-jq-fails"
mkdir -p "$quota_mktemp_bin" "$quota_mv_bin" "$quota_jq_bin"
cat >"$quota_mktemp_bin/mktemp" <<EOF
#!/bin/sh
case "\$1" in
  */.stderr.*) exit 1 ;;
esac
exec "$quota_real_mktemp" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' >"$quota_mv_bin/mv"
cat >"$quota_jq_bin/jq" <<EOF
#!/bin/sh
count_file="\${FAKE_JQ_COUNT:?}"
count=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$count" >"\$count_file"
[ "\$count" = "\${FAKE_JQ_FAIL_CALL:?}" ] && exit 5
exec "$quota_real_jq" "\$@"
EOF
chmod +x "$quota_mktemp_bin/mktemp" "$quota_mv_bin/mv" "$quota_jq_bin/jq"

quota_mktemp_home="$TEST_ROOT/quota-mktemp-home"
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 GLM_AGENT_HOME="$quota_mktemp_home" \
  PATH="$quota_mktemp_bin:$PATH"
assert_eq 'quota with a failing mktemp is a setup error' \
  '2||' "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
assert_contains 'quota names the directory it cannot write a temp file in' \
  "$STDERR" "$quota_mktemp_home/quota"
assert_eq 'a failing mktemp leaves no temp file behind' '' \
  "$(ls -A "$quota_mktemp_home/quota")"

quota_mv_home="$TEST_ROOT/quota-mv-home"
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 GLM_AGENT_HOME="$quota_mv_home" \
  PATH="$quota_mv_bin:$PATH"
assert_eq 'quota with a failing mv is a setup error' '2|' "$RC|$OUTPUT"
assert_contains 'quota names the artifact it cannot store' "$STDERR" \
  "$quota_mv_home/quota/response.json"
assert_eq 'a failing mv leaves no temp file behind' '' \
  "$(ls -A "$quota_mv_home/quota")"

# A jq failure after curl returned still ends in a full INVALID block.
for jq_fail_call in 2 3; do
  : >"$TEST_ROOT/quota-jq.count"
  quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 PATH="$quota_jq_bin:$PATH" \
    GLM_AGENT_HOME="$TEST_ROOT/quota-jq-home" \
    FAKE_JQ_COUNT="$TEST_ROOT/quota-jq.count" FAKE_JQ_FAIL_CALL="$jq_fail_call"
  assert_eq "jq failing on call $jq_fail_call is invalid-response" \
    "1|QUOTA_STATUS=INVALID|invalid-response" \
    "$RC|$(printf '%s\n' "$OUTPUT" | sed -n '1p')|$(printf '%s\n' "$OUTPUT" | sed -n 's/^ERROR_KIND=//p')"
done

# TERM during the lookup removes the temp files and exits 143. Bash runs a trap
# only after its foreground command ends, so the fake curl is released after
# the signal; a real interrupt also stops curl itself.
quota_term_home="$TEST_ROOT/quota-term-home"
quota_term_started="$TEST_ROOT/quota-term.started"
quota_term_release="$TEST_ROOT/quota-term.release"
: >"$FAKE_CURL_LOG"
: >"$FAKE_CURL_STDIN"
env -u ZAI_BASE_URL ZAI_API_KEY="$QUOTA_KEY" GLM_AGENT_HOME="$quota_term_home" \
  FAKE_CURL_STATUS=200 FAKE_CURL_BODY_FILE="$QUOTA_FIXTURES/ok.json" \
  FAKE_CURL_EXIT=0 FAKE_CURL_LOG="$FAKE_CURL_LOG" \
  FAKE_CURL_STDIN="$FAKE_CURL_STDIN" \
  FAKE_CURL_BLOCK_STARTED="$quota_term_started" \
  FAKE_CURL_BLOCK_RELEASE="$quota_term_release" \
  "$SCRIPT" quota >"$TEST_ROOT/quota-term.out" 2>"$TEST_ROOT/quota-term.err" &
quota_term_pid=$!
for _ in {1..500}; do
  [[ -f "$quota_term_started" ]] && break
  sleep 0.01
done
kill -TERM "$quota_term_pid" 2>/dev/null || true
: >"$quota_term_release"
if wait "$quota_term_pid"; then quota_term_rc=0; else quota_term_rc=$?; fi
assert_eq 'TERM during a quota lookup exits 143' '143' "$quota_term_rc"
assert_eq 'TERM during a quota lookup prints nothing' '' \
  "$(cat "$TEST_ROOT/quota-term.out")$(cat "$TEST_ROOT/quota-term.err")"
assert_eq 'TERM during a quota lookup leaves no temp file behind' '' \
  "$(ls -A "$quota_term_home/quota")"

# --- quota: the API key is never printed or stored ---------------------------
assert_not_contains 'quota success and configuration cases never print the key' \
  "$QUOTA_SEEN" "$QUOTA_KEY"
if grep -rqF -- "$QUOTA_KEY" "$QUOTA_HOME"; then
  fail 'quota state files never contain the key' "key found under $QUOTA_HOME"
else
  pass 'quota state files never contain the key'
fi

# --- quota: failure classification (exit 1, QUOTA_STATUS=INVALID) ------------
QUOTA_SEEN=''

cat >"$QUOTA_FIXTURES/code-1001.json" <<'JSON'
{"code":1001,"msg":"Header Authorization missing or invalid","success":false}
JSON
cat >"$QUOTA_FIXTURES/code-1113.json" <<'JSON'
{"code":1113,"msg":"Insufficient balance","success":false}
JSON
cat >"$QUOTA_FIXTURES/code-1302.json" <<'JSON'
{"code":1302,"msg":"Rate limit reached","success":false}
JSON
cat >"$QUOTA_FIXTURES/code-1211.json" <<'JSON'
{"code":1211,"msg":"Unknown model","success":false}
JSON
cat >"$QUOTA_FIXTURES/code-9999.json" <<'JSON'
{"code":9999,"msg":"Unexpected","success":false}
JSON
cat >"$QUOTA_FIXTURES/code-404.json" <<'JSON'
{"code":404,"msg":"Not found","success":false}
JSON
cat >"$QUOTA_FIXTURES/declined-200.json" <<'JSON'
{"code":200,"msg":"declined","success":false}
JSON
cat >"$QUOTA_FIXTURES/no-limits.json" <<'JSON'
{"code":200,"msg":"ok","data":{"level":"lite"},"success":true}
JSON
cat >"$QUOTA_FIXTURES/data-null.json" <<'JSON'
{"code":200,"msg":"ok","data":null,"success":true}
JSON
sed 's/"code":200,/"code":200.0,/' "$QUOTA_FIXTURES/ok.json" \
  >"$QUOTA_FIXTURES/code-200-float.json"
printf '%s\n' '<html>bad gateway</html>' >"$QUOTA_FIXTURES/not-json.txt"
printf '%s\n' '[]' >"$QUOTA_FIXTURES/array.json"
{ cat "$QUOTA_FIXTURES/ok.json"; printf 'trailing garbage\n'; } \
  >"$QUOTA_FIXTURES/trailing-garbage.json"
{ printf '\357\273\277'; cat "$QUOTA_FIXTURES/ok.json"; } \
  >"$QUOTA_FIXTURES/bom.json"

# assert_quota_failure <name> <error-kind> <provider-code>
# Checks the exit status and the complete four-line failure output.
assert_quota_failure() {
  local name="$1" kind="$2" code="$3" expected
  expected="$(printf 'QUOTA_STATUS=INVALID\nRESPONSE=%s\nERROR_KIND=%s\nPROVIDER_CODE=%s' \
    "$QUOTA_HOME/quota/response.json" "$kind" "$code")"
  assert_eq "$name" "1|$expected" "$RC|$OUTPUT"
}

# Rows 1-3: transport and HTTP status decide before the body is read.
quota_case 000 '' 28
assert_quota_failure 'curl timeout is provider-transient' provider-transient ''
assert_eq 'curl failure leaves an empty raw response' '' \
  "$(cat "$QUOTA_HOME/quota/response.json")"
assert_contains 'curl failure keeps curl stderr' \
  "$(cat "$QUOTA_HOME/quota/stderr.log")" 'curl: (28)'
quota_case 000 '' 6
assert_quota_failure 'curl network error is provider-transient' \
  provider-transient ''
quota_case 401 '' 0
assert_quota_failure 'HTTP 401 is authentication' authentication ''
quota_case 403 "$QUOTA_FIXTURES/code-1001.json" 0
assert_quota_failure 'HTTP 403 keeps the provider code' authentication 1001
assert_eq 'HTTP failure keeps the raw body' \
  "$(cat "$QUOTA_FIXTURES/code-1001.json")" \
  "$(cat "$QUOTA_HOME/quota/response.json")"
quota_case 429 '' 0
assert_quota_failure 'HTTP 429 is provider-transient' provider-transient ''
for http_status in 500 503; do
  quota_case "$http_status" '' 0
  assert_quota_failure "HTTP $http_status is provider-transient" \
    provider-transient ''
done

# A curl failure wins even when curl already saw a status and a valid body.
quota_case 200 "$QUOTA_FIXTURES/code-1113.json" 28
assert_quota_failure 'curl failure outranks an HTTP 200 body with code 1113' \
  provider-transient 1113

# A classified body code refines the HTTP row; an unknown code keeps the row.
quota_case 429 "$QUOTA_FIXTURES/code-1113.json" 0
assert_quota_failure 'HTTP 429 with body code 1113 is quota-exhausted' \
  quota-exhausted 1113
quota_case 503 "$QUOTA_FIXTURES/code-1113.json" 0
assert_quota_failure 'HTTP 503 with body code 1113 is quota-exhausted' \
  quota-exhausted 1113
quota_case 429 "$QUOTA_FIXTURES/code-9999.json" 0
assert_quota_failure 'HTTP 429 with an unknown body code stays provider-transient' \
  provider-transient 9999
quota_case 401 "$QUOTA_FIXTURES/code-1001.json" 0
assert_quota_failure 'HTTP 401 with body code 1001 is authentication' \
  authentication 1001
quota_case 401 "$QUOTA_FIXTURES/code-9999.json" 0
assert_quota_failure 'HTTP 401 with an unknown body code stays authentication' \
  authentication 9999
quota_case 404 "$QUOTA_FIXTURES/code-1113.json" 0
assert_quota_failure 'HTTP 404 with body code 1113 is quota-exhausted' \
  quota-exhausted 1113
quota_case 429 "$QUOTA_FIXTURES/not-json.txt" 0
assert_quota_failure 'HTTP 429 with a text body stays provider-transient' \
  provider-transient ''

# Row 4: a provider error inside the body reuses classify_error_kind.
quota_case 200 "$QUOTA_FIXTURES/code-1001.json" 0
assert_quota_failure 'body code 1001 is authentication' authentication 1001
quota_case 200 "$QUOTA_FIXTURES/code-1113.json" 0
assert_quota_failure 'body code 1113 is quota-exhausted' quota-exhausted 1113
quota_case 200 "$QUOTA_FIXTURES/code-1302.json" 0
assert_quota_failure 'body code 1302 is provider-transient' \
  provider-transient 1302
quota_case 200 "$QUOTA_FIXTURES/code-1211.json" 0
assert_quota_failure 'body code 1211 is model-unavailable' \
  model-unavailable 1211
quota_case 200 "$QUOTA_FIXTURES/code-9999.json" 0
assert_quota_failure 'unlisted body code is provider-error' provider-error 9999
quota_case 200 "$QUOTA_FIXTURES/declined-200.json" 0
assert_quota_failure 'success:false with code 200 has no provider code' \
  provider-error ''

# Row 6: other non-200 statuses.
quota_case 404 "$QUOTA_FIXTURES/not-json.txt" 0
assert_quota_failure 'HTTP 404 with a text body is provider-error' \
  provider-error ''
quota_case 404 "$QUOTA_FIXTURES/code-404.json" 0
assert_quota_failure 'HTTP 404 with a JSON body keeps its code' \
  provider-error 404
quota_case 302 "$QUOTA_FIXTURES/ok.json" 0
assert_quota_failure 'HTTP 302 is never a successful lookup' provider-error ''

# Row 5: HTTP 200 whose body is not a usable quota document.
quota_case 200 "$QUOTA_FIXTURES/not-json.txt" 0
assert_quota_failure 'HTTP 200 with a text body is invalid-response' \
  invalid-response ''
quota_case 200 "$QUOTA_FIXTURES/no-limits.json" 0
assert_quota_failure 'missing data.limits is invalid-response' \
  invalid-response ''
quota_case 200 "$QUOTA_FIXTURES/data-null.json" 0
assert_quota_failure 'success:true with null data is invalid-response' \
  invalid-response ''
quota_case 200 "$QUOTA_FIXTURES/array.json" 0
assert_quota_failure 'a JSON array body is invalid-response' invalid-response ''
quota_case 200 '' 0
assert_quota_failure 'an empty body is invalid-response' invalid-response ''
quota_case 200 "$QUOTA_FIXTURES/trailing-garbage.json" 0
assert_quota_failure 'trailing garbage after the JSON is invalid-response' \
  invalid-response ''

# A UTF-8 BOM before otherwise valid JSON is accepted (jq strips it).
quota_case 200 "$QUOTA_FIXTURES/bom.json" 0
assert_eq 'a BOM-prefixed response is accepted' "0|$expected_quota_ok" \
  "$RC|$OUTPUT"

# The success check is numeric: code 200.0 is still code 200.
quota_case 200 "$QUOTA_FIXTURES/code-200-float.json" 0
assert_eq 'body code 200.0 counts as success' \
  "0|$(printf '%s\n' "$expected_quota_ok" | sed -n '1p')" \
  "$RC|$(printf '%s\n' "$OUTPUT" | sed -n '1p')"

assert_eq 'failures leave exactly the two raw artifacts' \
  $'response.json\nstderr.log' "$(ls -A "$QUOTA_HOME/quota")"
assert_not_contains 'quota failure cases never print the key' \
  "$QUOTA_SEEN" "$QUOTA_KEY"
if grep -rqF -- "$QUOTA_KEY" "$QUOTA_HOME"; then
  fail 'quota failure artifacts never contain the key' \
    "key found under $QUOTA_HOME"
else
  pass 'quota failure artifacts never contain the key'
fi

# --- quota: README example matches the CLI output ----------------------------
readme_quota_example="$(sed -n '/^QUOTA_STATUS=OK$/,/^PROVIDER_CODE=$/p' \
  "$REPO_DIR/README.md" | sed '/^RESPONSE=/d')"
actual_quota_example="$(printf '%s\n' "$expected_quota_ok" |
  sed '/^RESPONSE=/d')"
assert_eq 'README quota example matches the CLI output' \
  "$actual_quota_example" "$readme_quota_example"

printf '1..%d\n' "$tests"
if ((failures > 0)); then
  printf '# %d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '# all %d tests passed\n' "$tests"
