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
  sleep 60 &
  fake_child_pid=$!
  printf '%s\n' "$fake_child_pid" >"$FAKE_CLAUDE_CHILD_PID_FILE"
  ps -o pgid= -p "$$" | tr -d ' ' >"$FAKE_CLAUDE_PROVIDER_PGID_FILE"
  : >"$FAKE_CLAUDE_HANG_STARTED"
  cleanup_fake_child() {
    kill "$fake_child_pid" 2>/dev/null || true
    wait "$fake_child_pid" 2>/dev/null || true
  }
  trap cleanup_fake_child EXIT
  for _ in {1..1000}; do
    [[ -f "$FAKE_CLAUDE_HANG_RELEASE" ]] && break
    sleep 0.01
  done
  [[ -f "$FAKE_CLAUDE_HANG_RELEASE" ]] || exit 19
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
assert_contains 'help documents role option' "$help_output" \
  'start [--role <role>] [--model <alias>]'
assert_contains 'help documents explorer role' "$help_output" 'explorer'
assert_contains 'help documents fallback signal' "$help_output" \
  'FALLBACK_RECOMMENDED'
assert_eq 'version is available' 'glm-agent 0.3.0' "$($SCRIPT --version)"

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

async_started="$TEST_ROOT/async.started"
async_release="$TEST_ROOT/async.release"
async_receipt="$TEST_ROOT/async.receipt"
export FAKE_CLAUDE_BLOCK_STARTED="$async_started"
export FAKE_CLAUDE_BLOCK_RELEASE="$async_release"
if (
  "$SCRIPT" start --async --role explorer --model haiku --cwd "$PROJECT" \
    'WAIT_FOR_RELEASE async parent exit'
) >"$async_receipt" 2>"$TEST_ROOT/async-start.err"; then
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
capture "$SCRIPT" start --async --cwd "$PROJECT" 'HANG_WITH_CHILD cancel me'
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
cancel_stderr="$STDERR"
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
for _ in {1..100}; do
  if ! kill -0 "$cancel_child_pid" 2>/dev/null; then
    break
  fi
  sleep 0.01
done
if ! kill -0 "$cancel_child_pid" 2>/dev/null; then
  pass 'cancel terminates provider child processes'
else
  fail 'cancel terminates provider child processes' \
    "child $cancel_child_pid remains in provider group $cancel_provider_pgid"
fi

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

capture "$SCRIPT" start --cwd "$PROJECT" 'pre-provider cancel fixture'
assert_eq 'pre-provider cancel fixture starts' '0' "$RC"
pre_cancel_worker_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
pre_cancel_dir="$GLM_AGENT_HOME/workers/$pre_cancel_worker_id"
mkdir "$pre_cancel_dir/turns/0002" "$pre_cancel_dir/active"
printf '%s\n' 'headless' >"$pre_cancel_dir/turns/0002/mode"
printf '%s\n' 'provider must not start' >"$pre_cancel_dir/turns/0002/prompt.md"
cat >"$pre_cancel_dir/active/state" <<EOF
mode=headless
turn=2
supervision=async
runner_pid=
provider_pgid=
started_at=$(date +%s)
EOF
sed 's/^status=.*/status=RUNNING/; s/^turn=.*/turn=2/' \
  "$pre_cancel_dir/meta" >"$pre_cancel_dir/meta.next"
mv "$pre_cancel_dir/meta.next" "$pre_cancel_dir/meta"
"$SCRIPT" _execute-turn "$pre_cancel_worker_id" 2 \
  >"$pre_cancel_dir/turns/0002/runner.log" 2>&1 &
pre_cancel_runner_pid=$!
sed "s/^runner_pid=.*/runner_pid=$pre_cancel_runner_pid/" \
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
mode=headless
turn=2
supervision=sync
runner_pid=$$
provider_pgid=
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
mode=headless
turn=2
runner_pid=99999999
provider_pgid=
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

printf '1..%d\n' "$tests"
if ((failures > 0)); then
  printf '# %d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '# all %d tests passed\n' "$tests"
