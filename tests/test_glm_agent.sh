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
  printf 'session_id_arg=%s\n' "${session_id_arg:-NEVER_PASSED}"
  printf 'invocation_mode=%s\n' "$invocation_mode"
  printf 'result_file=%s\n' "${GLM_RESULT_FILE:-NEVER_SET}"
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

if [[ "$invocation_mode" == "tui" ]]; then
  # A TUI session is the User's own main session: no worker contract, no
  # result protocol. It just runs (or fails when simulating an error).
  if [[ "${FAKE_TUI_BEHAVIOR:-}" == fail ]]; then
    printf '%s\n' 'simulated TUI failure' >&2
    exit 21
  fi
  exit 0
fi

if [[ -z "${GLM_RESULT_FILE:-}" ]]; then
  printf '%s\n' 'RUN_OK'
  exit 0
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

if [[ "$prompt" == *EMPTY_REPLY* ]]; then
  printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","result":""}\n' "$session_id"
  exit 0
fi

if [[ "$prompt" == *MULTILINE_REPLY* ]]; then
  printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","result":"first reply line\\nsecond reply line"}\n' "$session_id"
  exit 0
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
assert_contains 'help documents durable result status' "$help_output" 'STATUS=DONE|BLOCKED|NO_REPORT|INVALID'
assert_contains 'help documents NO_REPORT' "$help_output" \
  'NO_REPORT The turn ended without a valid result file. The work may be done.'
assert_contains 'help says NO_REPORT is not an error' "$help_output" \
  'This is not an error: do not close the worker or resend the task.'
assert_contains 'help documents the NO_REPORT output keys' "$help_output" \
  'REASON, REPLY, and NEXT'
assert_contains 'help documents the retention variable' "$help_output" \
  'GLM_WORKER_RETENTION_DAYS'
assert_contains 'help documents the retention default' "$help_output" \
  'Default: 21. 0 turns the cleanup off.'
assert_contains 'help explains close preserves history' "$help_output" 'does not delete its history'
assert_contains 'help documents role option' "$help_output" \
  'start [--role <role>] [--model <alias>]'
assert_contains 'help documents explorer role' "$help_output" 'explorer'
assert_contains 'help documents fallback signal' "$help_output" \
  'FALLBACK_RECOMMENDED'
assert_contains 'help documents the plain TUI session' "$help_output" \
  'glm-agent tui [--model <alias>] [--cwd <directory>] [--resume <session-id>]'
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
assert_contains 'help lists team-scope in the usage synopsis' "$help_output" \
  $'\n  glm-agent team-scope [<organization> <project> | --clear]\n'
assert_contains 'help documents the quota command' "$help_output" \
  $'\n    quota\n'
assert_contains 'help documents the team-scope command' "$help_output" \
  $'\n  team-scope [<organization> <project> | --clear]\n'
assert_contains 'help lists auth add personal in the usage synopsis' \
  "$help_output" \
  $'\n  glm-agent auth add personal --name <name> --api-key <key>\n'
assert_contains 'help lists auth add team in the usage synopsis' \
  "$help_output" \
  $'\n  glm-agent auth add team --name <name> --api-key <key> --organization <org> --project <project>\n'
assert_contains 'help lists auth switch in the usage synopsis' "$help_output" \
  $'\n  glm-agent auth switch <name>\n'
assert_contains 'help lists auth remove in the usage synopsis' "$help_output" \
  $'\n  glm-agent auth remove <name>\n'
assert_contains 'help lists auth list in the usage synopsis' "$help_output" \
  $'\n  glm-agent auth list\n'
assert_contains 'help documents auth add personal' "$help_output" \
  $'\n  auth add personal --name <name> --api-key <key>\n'
assert_contains 'help documents auth add team' "$help_output" \
  $'\n  auth add team --name <name> --api-key <key> --organization <org> --project <project>\n'
assert_contains 'help documents auth switch' "$help_output" \
  $'\n  auth switch <name>\n'
assert_contains 'help documents auth remove' "$help_output" \
  $'\n  auth remove <name>\n'
assert_contains 'help documents auth list' "$help_output" $'\n  auth list\n'
assert_contains 'help documents the stdin key' "$help_output" \
  '--api-key - reads the key'
assert_contains 'help documents the auth add receipt' "$help_output" \
  'ACCOUNT=ADDED'
assert_contains 'help documents the auth switch receipt' "$help_output" \
  'ACCOUNT=ACTIVE'
assert_contains 'help documents the auth remove receipt' "$help_output" \
  'ACCOUNT=REMOVED'
assert_contains 'help documents the auth list fields' "$help_output" \
  'ACCOUNT_<i>_NAME'
assert_contains 'help documents the legacy migration line' "$help_output" \
  'MIGRATED_ACCOUNT=<name>'
assert_contains 'help documents the non-atomic link change' "$help_output" \
  'not one atomic step'
assert_contains 'help documents the account directory mode' "$help_output" \
  '.glm/accounts/<name>/'
assert_not_contains 'help no longer calls .env.auth the key file' \
  "$help_output" '.glm/.env.auth is mode 0600'
assert_contains 'help documents the quota scope field' "$help_output" \
  'SCOPE=personal|team'
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
assert_eq 'version is available' "glm-agent $(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$SCRIPT")" "$($SCRIPT --version)"

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
capture "$SCRIPT" tui --cwd "$OTHER_PROJECT"
assert_eq 'new TUI session exits successfully' '0' "$RC"
tui_session_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^SESSION_ID=//p')"
if [[ "$tui_session_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
  pass 'new TUI prints a UUIDv4 session id for later resume'
else
  fail 'new TUI prints a UUIDv4 session id for later resume' \
    "invalid session: $tui_session_id"
fi
assert_contains 'new TUI prints its cwd' "$OUTPUT" "CWD=$OTHER_PROJECT"
assert_contains 'new TUI reports the exit code' "$OUTPUT" 'EXIT_CODE=0'
tui_worker_count="$(find "$GLM_AGENT_HOME/workers" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
tui_log="$(cat "$FAKE_LOG")"
assert_contains 'new TUI invokes interactive Claude mode' "$tui_log" \
  'invocation_mode=tui'
assert_contains 'new TUI runs in the selected cwd' "$tui_log" "cwd=$OTHER_PROJECT"
assert_contains 'new TUI passes its allocated session id' "$tui_log" \
  "session_id_arg=$tui_session_id"
assert_contains 'new TUI bypasses permissions for interactive use' "$tui_log" \
  'permission_bypass=yes'
assert_contains 'new TUI adds no worker contract prompt' "$tui_log" \
  'contract=missing'
assert_contains 'new TUI adds no role prompt' "$tui_log" 'role_prompt=missing'
assert_contains 'new TUI sets no result file' "$tui_log" \
  'result_file=NEVER_SET'

: >"$FAKE_LOG"
capture "$SCRIPT" tui --model opus --cwd "$OTHER_PROJECT" --resume \
  "$tui_session_id"
assert_eq 'TUI resume exits successfully' '0' "$RC"
assert_contains 'TUI resume prints the resume receipt' "$OUTPUT" \
  "RESUME=$tui_session_id"
assert_contains 'TUI resume reports the exit code' "$OUTPUT" 'EXIT_CODE=0'
resume_log="$(cat "$FAKE_LOG")"
assert_contains 'TUI resume resumes the stored session' "$resume_log" \
  "resume=$tui_session_id"
assert_contains 'TUI resume passes the selected model' "$resume_log" \
  'model=opus'
assert_contains 'TUI resume allocates no new session id' "$resume_log" \
  'session_id_arg=NEVER_PASSED'
assert_contains 'TUI resume adds no worker contract prompt' "$resume_log" \
  'contract=missing'
assert_eq 'TUI creates no worker directory' "$tui_worker_count" \
  "$(find "$GLM_AGENT_HOME/workers" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"

capture "$SCRIPT" tui "$tui_session_id"
assert_eq 'TUI rejects positional worker-ids' '2' "$RC"
assert_contains 'TUI positional rejection points at --resume' "$STDERR" \
  '--resume'

capture "$SCRIPT" tui --resume
assert_eq 'TUI rejects a valueless resume' '2' "$RC"

capture "$SCRIPT" tui --role explorer
assert_eq 'TUI rejects worker roles' '2' "$RC"

export FAKE_TUI_BEHAVIOR=fail
capture "$SCRIPT" tui --cwd "$OTHER_PROJECT"
assert_eq 'nonzero TUI exit propagates' '21' "$RC"
assert_contains 'nonzero TUI exit reports the code' "$OUTPUT" 'EXIT_CODE=21'
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
assert_eq 'missing result is not a command failure' '0' "$RC"
assert_contains 'missing result reports NO_REPORT' "$OUTPUT" 'STATUS=NO_REPORT'
assert_contains 'missing result names the reason' "$OUTPUT" 'REASON=result-file-missing'
assert_not_contains 'missing result prints no ERROR line' "$OUTPUT" $'\nERROR='
assert_contains 'missing result has an empty error kind' "$OUTPUT" $'ERROR_KIND=\n'
assert_contains 'missing result does not fallback' "$OUTPUT" \
  'FALLBACK_RECOMMENDED=false'
missing_result_turn="$(meta_get_test "$meta" turn)"
if [[ "$missing_result_turn" =~ ^[0-9]+$ ]]; then
  pass 'NO_REPORT turn is retained in history'
else
  fail 'NO_REPORT turn is retained in history' "invalid turn: $missing_result_turn"
fi
printf -v missing_result_label '%04d' "$((10#$missing_result_turn))"
missing_reply="$GLM_AGENT_HOME/workers/$worker_id/turns/$missing_result_label/reply.md"
assert_contains 'missing result reports the reply path' "$OUTPUT" "REPLY=$missing_reply"
assert_contains 'missing result points to the reply' "$OUTPUT" 'NEXT=read-reply'
assert_eq 'reply file holds the worker reply' 'ok' "$(cat "$missing_reply")"
assert_eq 'reply file is private' '600' "$(file_mode "$missing_reply")"
assert_eq 'NO_REPORT turn updates worker status' 'NO_REPORT' "$(meta_get_test "$meta" status)"
assert_eq 'NO_REPORT turn stores the reason' 'result-file-missing' "$(meta_get_test "$meta" reason)"
assert_eq 'NO_REPORT turn keeps prior canonical result' "$send_result" "$($SCRIPT result "$worker_id")"

capture "$SCRIPT" send "$worker_id" 'MALFORMED_RESULT'
assert_eq 'malformed result is not a command failure' '0' "$RC"
assert_contains 'malformed result reports NO_REPORT' "$OUTPUT" 'STATUS=NO_REPORT'
assert_contains 'malformed result names the reason' "$OUTPUT" 'REASON=result-status-invalid'
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

capture "$SCRIPT" start --cwd "$PROJECT" 'MISSING_RESULT EMPTY_REPLY'
assert_eq 'empty reply is not a command failure' '0' "$RC"
assert_contains 'empty reply reports NO_REPORT' "$OUTPUT" 'STATUS=NO_REPORT'
assert_contains 'empty reply leaves the reply path empty' "$OUTPUT" $'REPLY=\n'
assert_contains 'empty reply asks for a change inspection' "$OUTPUT" 'NEXT=inspect-changes'
empty_reply_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
if [[ ! -e "$GLM_AGENT_HOME/workers/$empty_reply_id/turns/0001/reply.md" ]]; then
  pass 'empty reply writes no reply file'
else
  fail 'empty reply writes no reply file' 'reply.md exists'
fi

capture "$SCRIPT" start --cwd "$PROJECT" 'MISSING_RESULT MULTILINE_REPLY'
multiline_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
assert_eq 'a multi-line reply is stored whole' $'first reply line\nsecond reply line' \
  "$(cat "$GLM_AGENT_HOME/workers/$multiline_id/turns/0001/reply.md")"
assert_not_contains 'stdout carries the reply path and not the reply' "$OUTPUT" 'first reply line'

capture "$SCRIPT" start --cwd "$PROJECT" 'MISSING_RESULT observe'
no_report_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
no_report_meta="$GLM_AGENT_HOME/workers/$no_report_id/meta"
no_report_reply="$GLM_AGENT_HOME/workers/$no_report_id/turns/0001/reply.md"

capture "$SCRIPT" status "$no_report_id"
assert_eq 'status of a NO_REPORT worker succeeds' '0' "$RC"
assert_contains 'status reports NO_REPORT' "$OUTPUT" 'STATUS=NO_REPORT'
assert_contains 'status reports the reason' "$OUTPUT" 'REASON=result-file-missing'
assert_contains 'status reports the reply path' "$OUTPUT" "REPLY=$no_report_reply"
assert_contains 'status points to the reply' "$OUTPUT" 'NEXT=read-reply'

capture "$SCRIPT" wait --timeout 0 "$no_report_id"
assert_eq 'wait on a NO_REPORT worker succeeds' '0' "$RC"
assert_contains 'wait treats NO_REPORT as terminal' "$OUTPUT" 'WAIT_RESULT=TERMINAL'
assert_contains 'wait reports NO_REPORT' "$OUTPUT" 'STATUS=NO_REPORT'
assert_contains 'wait reports the reason' "$OUTPUT" 'REASON=result-file-missing'

capture "$SCRIPT" cancel "$no_report_id"
assert_eq 'cancel on a NO_REPORT worker succeeds' '0' "$RC"
assert_contains 'cancel reports a NO_REPORT worker as already terminal' "$OUTPUT" \
  'CANCEL_RESULT=ALREADY_TERMINAL'

capture "$SCRIPT" list
assert_contains 'list shows the NO_REPORT worker' "$OUTPUT" \
  "WORKER_ID=$no_report_id"$'\tSTATUS=NO_REPORT'

capture "$SCRIPT" send "$no_report_id" 'follow up after no report'
assert_eq 'send to a NO_REPORT worker succeeds' '0' "$RC"
assert_contains 'send after NO_REPORT reaches DONE' "$OUTPUT" 'STATUS=DONE'
assert_not_contains 'a DONE turn prints no REASON line' "$OUTPUT" 'REASON='
assert_eq 'a later turn clears the reason' '' "$(meta_get_test "$no_report_meta" reason)"
assert_eq 'a later turn clears the reply' '' "$(meta_get_test "$no_report_meta" reply)"

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

# store_quota_key <key>: seeds the stored credential quota reads.
store_quota_key() {
  printf '%s\n' "$1" >"$QUOTA_HOME/.env.auth"
}
mkdir -p "$QUOTA_HOME"
store_quota_key "$QUOTA_KEY"

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
# Runs "glm-agent quota" against the fake curl and records the run. A
# GLM_AGENT_HOME override is seeded with the stored key first.
quota_case() {
  local status="$1" body="$2" curl_exit="$3" var home="$QUOTA_HOME"
  shift 3
  for var in "$@"; do
    [[ "$var" == GLM_AGENT_HOME=* ]] && home="${var#GLM_AGENT_HOME=}"
  done
  mkdir -p "$home"
  [[ -f "$home/.env.auth" ]] || printf '%s\n' "$QUOTA_KEY" >"$home/.env.auth"
  : >"$FAKE_CURL_LOG"
  : >"$FAKE_CURL_STDIN"
  capture env -u ZAI_API_KEY -u ZAI_BASE_URL -u ZAI_QUOTA_ORGANIZATION \
    -u ZAI_QUOTA_PROJECT \
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
SCOPE=personal
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

# --- team-scope: stored selectors switch quota to the team plan ---------------
QUOTA_ORG='org-Team42TestORG0123456789ab'
QUOTA_PROJ='proj_Team42TestPRJ0123456789ab'
TEAM_SCOPE_FILE="$QUOTA_HOME/.env.team-scope"
expected_quota_ok_team="$(printf '%s\n' "$expected_quota_ok" |
  sed 's/^SCOPE=personal$/SCOPE=team/')"

capture env GLM_AGENT_HOME="$QUOTA_HOME" "$SCRIPT" team-scope \
  "$QUOTA_ORG" "$QUOTA_PROJ"
assert_eq 'team-scope store succeeds' '0' "$RC"
assert_eq 'team-scope store prints a receipt' \
  $'TEAM_SCOPE=SAVED\nORGANIZATION='"$QUOTA_ORG"$'\nPROJECT='"$QUOTA_PROJ" \
  "$OUTPUT"
assert_eq 'team-scope file holds both selectors' \
  $'organization='"$QUOTA_ORG"$'\nproject='"$QUOTA_PROJ" \
  "$(cat "$TEAM_SCOPE_FILE")"
assert_eq 'team-scope file is private' '600' "$(file_mode "$TEAM_SCOPE_FILE")"

capture env GLM_AGENT_HOME="$QUOTA_HOME" "$SCRIPT" team-scope
assert_eq 'team-scope status reports the team scope' \
  $'TEAM_SCOPE=team\nORGANIZATION='"$QUOTA_ORG"$'\nPROJECT='"$QUOTA_PROJ" \
  "$OUTPUT"

quota_case 200 "$QUOTA_FIXTURES/ok.json" 0
assert_eq 'stored team scope keeps the lookup successful' '0' "$RC"
assert_eq 'quota prints the documented fields for a team scope' \
  "$expected_quota_ok_team" "$OUTPUT"
assert_eq 'team scope targets the monitor endpoint with type=2' \
  'arg=https://api.z.ai/api/monitor/usage/quota/limit?type=2' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"
assert_eq 'team scope sends the key and selectors as stdin headers' \
  $'Authorization: '"$QUOTA_KEY"$'\nBigmodel-Organization: '"$QUOTA_ORG"$'\nBigmodel-Project: '"$QUOTA_PROJ" \
  "$(cat "$FAKE_CURL_STDIN")"
assert_not_contains 'team scope keeps the organization out of curl argv' \
  "$(cat "$FAKE_CURL_LOG")" "$QUOTA_ORG"
assert_not_contains 'team scope keeps the project out of curl argv' \
  "$(cat "$FAKE_CURL_LOG")" "$QUOTA_PROJ"

quota_env_home="$TEST_ROOT/quota-env-home"
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 GLM_AGENT_HOME="$quota_env_home" \
  ZAI_QUOTA_ORGANIZATION="$QUOTA_ORG" ZAI_QUOTA_PROJECT="$QUOTA_PROJ"
assert_eq 'environment team scope keeps the lookup successful' '0' "$RC"
assert_contains 'environment team scope prints SCOPE=team' "$OUTPUT" \
  $'SCOPE=team\n'
assert_eq 'environment team scope also targets type=2' \
  'arg=https://api.z.ai/api/monitor/usage/quota/limit?type=2' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"

quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 ZAI_QUOTA_PROJECT="$QUOTA_PROJ-2"
assert_contains 'environment project overrides the stored project' \
  "$(cat "$FAKE_CURL_STDIN")" "Bigmodel-Project: $QUOTA_PROJ-2"
assert_contains 'the stored organization still applies' \
  "$(cat "$FAKE_CURL_STDIN")" "Bigmodel-Organization: $QUOTA_ORG"

quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 GLM_AGENT_HOME="$quota_env_home" \
  ZAI_QUOTA_PROJECT="$QUOTA_PROJ"
assert_eq 'one-sided team scope is a configuration error' '2||' \
  "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
assert_contains 'one-sided scope names the requirement' "$STDERR" \
  'team scope needs both an organization and a project'

printf 'organization=%s\n' "$QUOTA_ORG" >"$TEAM_SCOPE_FILE"
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0
assert_eq 'malformed team scope file is a configuration error' '2||' \
  "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
assert_contains 'malformed scope error names the file' "$STDERR" \
  "$TEAM_SCOPE_FILE"

capture env GLM_AGENT_HOME="$QUOTA_HOME" "$SCRIPT" team-scope "$QUOTA_ORG"
assert_eq 'team-scope rejects a single selector' '2|' "$RC|$OUTPUT"
capture env GLM_AGENT_HOME="$QUOTA_HOME" "$SCRIPT" team-scope \
  "$QUOTA_ORG" "$QUOTA_PROJ" extra
assert_eq 'team-scope rejects three arguments' '2|' "$RC|$OUTPUT"
capture env GLM_AGENT_HOME="$QUOTA_HOME" "$SCRIPT" team-scope '' "$QUOTA_PROJ"
assert_eq 'team-scope rejects an empty organization' '2|' "$RC|$OUTPUT"
capture env GLM_AGENT_HOME="$QUOTA_HOME" "$SCRIPT" team-scope \
  "$QUOTA_ORG"$'\n' "$QUOTA_PROJ"
assert_eq 'team-scope rejects a multi-line organization' '2|' "$RC|$OUTPUT"
capture env GLM_AGENT_HOME="$QUOTA_HOME" "$SCRIPT" team-scope \
  --clear extra
assert_eq 'team-scope --clear accepts no other arguments' '2|' "$RC|$OUTPUT"

rm -f -- "$TEAM_SCOPE_FILE"
capture env GLM_AGENT_HOME="$QUOTA_HOME" "$SCRIPT" team-scope --clear
assert_eq 'team-scope clear succeeds' '0' "$RC"
assert_eq 'team-scope clear prints a receipt' 'TEAM_SCOPE=CLEARED' "$OUTPUT"
capture env GLM_AGENT_HOME="$QUOTA_HOME" "$SCRIPT" team-scope
assert_eq 'status without selectors reports the personal scope' \
  $'TEAM_SCOPE=personal\nORGANIZATION=\nPROJECT=' "$OUTPUT"

quota_case 200 "$QUOTA_FIXTURES/ok.json" 0
assert_contains 'quota after clear reports the personal scope' "$OUTPUT" \
  $'SCOPE=personal\n'
assert_eq 'personal scope targets the endpoint without type=2' \
  'arg=https://api.z.ai/api/monitor/usage/quota/limit' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"

# --- quota: usage and configuration errors (exit 2, empty stdout) ------------
capture env -u ZAI_API_KEY GLM_AGENT_HOME="$QUOTA_HOME" \
  "$SCRIPT" quota extra
quota_record
assert_eq 'quota rejects extra arguments' '2|' "$RC|$OUTPUT"
assert_contains 'quota argument error is clear' "$STDERR" \
  'quota does not accept arguments'

for bad_key in "$QUOTA_KEY"$'\rtail' "$QUOTA_KEY"$'\ntail'; do
  store_quota_key "$bad_key"
  quota_case 200 "$QUOTA_FIXTURES/ok.json" 0
  assert_eq 'multi-line API key is rejected before curl runs' \
    '2||' "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
  assert_contains 'multi-line API key error names the problem' "$STDERR" \
    'API key must be a single line'
done
store_quota_key "$QUOTA_KEY"

for bad_url in 'ftp://example.test' 'example.test/x' \
  'https://user@example.test/x' 'https://example.test:8a/x' \
  'https://example.test?x=1'; do
  quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 ZAI_BASE_URL="$bad_url"
  assert_eq "ZAI_BASE_URL [$bad_url] is rejected before curl runs" \
    '2||' "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
done

# The ZAI_API_KEY environment variable is never read: the stored file is the
# only key source, and an exported variable alone cannot authenticate quota.
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 ZAI_API_KEY='env-key-ignored-by-quota'
assert_eq 'quota ignores an exported ZAI_API_KEY' '0' "$RC"
assert_contains 'quota sends the stored key, not the env key' \
  "$(cat "$FAKE_CURL_STDIN")" "Authorization: $QUOTA_KEY"

envonly_home="$TEST_ROOT/quota-envonly-home"
capture env ZAI_API_KEY="$QUOTA_KEY" GLM_AGENT_HOME="$envonly_home" "$SCRIPT" quota
quota_record
assert_eq 'quota with only an env key is a configuration error' '2|' "$RC|$OUTPUT"
assert_contains 'env-only key error gives the setup instruction' "$STDERR" \
  'Run: glm-agent api-key'
if [[ ! -e "$envonly_home" ]]; then
  pass 'env-only key creates no state'
else
  fail 'env-only key creates no state' "unexpected path: $envonly_home"
fi

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
capture env -u ZAI_API_KEY PATH="$TEST_ROOT/quota-bin-no-curl" \
  GLM_AGENT_HOME="$QUOTA_HOME" "$BASH" "$SCRIPT" quota
quota_record
assert_eq 'quota without curl is a dependency error' '2|' "$RC|$OUTPUT"
assert_contains 'quota names the missing curl' "$STDERR" \
  'required command not found: curl'

make_quota_bin "$TEST_ROOT/quota-bin-no-jq" jq
capture env -u ZAI_API_KEY PATH="$TEST_ROOT/quota-bin-no-jq" \
  GLM_AGENT_HOME="$QUOTA_HOME" "$BASH" "$SCRIPT" quota
quota_record
assert_eq 'quota without jq is a dependency error' '2|' "$RC|$OUTPUT"
assert_contains 'quota names the missing jq' "$STDERR" \
  'required command not found: jq'

# --- quota: state and temp-file failures are setup errors (exit 2) ------------
# No exit path may end with status 1 and no QUOTA_STATUS line.
# A home that cannot be created at all is no longer reachable here: the key
# file lives inside the home, so an unwritable parent blocks the key read
# first, and an existing home is always chmod-able by its owner. The blocked
# quota directory and the mktemp/mv failures below cover the writable-state
# failures.

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
# load_api_key is shared, so start reports the same setup error.
if [[ "$(id -u)" == 0 ]]; then
  pass 'start unreadable key file (skipped: root ignores file modes)'
  pass 'start names the unreadable key file (skipped: root)'
else
  capture env -u ZAI_API_KEY GLM_AGENT_HOME="$quota_unreadable_home" \
    "$SCRIPT" start --cwd "$PROJECT" 'unreadable key task'
  assert_eq 'start with an unreadable key file is a setup error' \
    '2|' "$RC|$OUTPUT"
  assert_contains 'start names the unreadable key file' "$STDERR" \
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
mkdir -p "$quota_term_home"
printf '%s\n' "$QUOTA_KEY" >"$quota_term_home/.env.auth"
: >"$FAKE_CURL_LOG"
: >"$FAKE_CURL_STDIN"
env -u ZAI_API_KEY -u ZAI_BASE_URL GLM_AGENT_HOME="$quota_term_home" \
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
if grep -rqF --exclude='.env.auth' -- "$QUOTA_KEY" "$QUOTA_HOME"; then
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
# Checks the exit status and the complete five-line failure output.
assert_quota_failure() {
  local name="$1" kind="$2" code="$3" expected
  expected="$(printf 'QUOTA_STATUS=INVALID\nSCOPE=personal\nRESPONSE=%s\nERROR_KIND=%s\nPROVIDER_CODE=%s' \
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
if grep -rqF --exclude='.env.auth' -- "$QUOTA_KEY" "$QUOTA_HOME"; then
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

# --- auth: helpers -----------------------------------------------------------
AUTH_HOME="$TEST_ROOT/auth-home"
AUTH_SEEN=''
AUTH_KEY_LEGACY='fake-legacy-key-0001'
AUTH_KEY_ME='fake-me-key-0002'
AUTH_KEY_ACME='fake-acme-key-0003'
AUTH_KEY_OTHER='fake-other-key-0004'
AUTH_KEY_STDIN='fake-stdin-key-0005'
AUTH_KEY_ROTATED='fake-rotated-key-0006'
AUTH_ORG='org-AuthTestOrg0123456789'
AUTH_PROJ='proj_AuthTestProj0123456789'
AUTH_ORG_OTHER='org-AuthTestOther0123456789'
AUTH_PROJ_OTHER='proj_AuthTestOther0123456789'

auth_reset() {
  rm -rf -- "$AUTH_HOME"
}

# auth_cli <glm-agent args...>: runs the CLI against AUTH_HOME and records the
# output so the key scans at the end can prove no key was ever printed.
auth_cli() {
  capture env -u ZAI_API_KEY GLM_AGENT_HOME="$AUTH_HOME" "$SCRIPT" "$@"
  AUTH_SEEN+="$OUTPUT"$'\n'"$STDERR"$'\n'
}

# auth_quota: runs quota against AUTH_HOME with the fake curl.
auth_quota() {
  quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 GLM_AGENT_HOME="$AUTH_HOME"
  AUTH_SEEN+="$OUTPUT"$'\n'"$STDERR"$'\n'
}

# auth_tmp_leftovers: lists temporary links that a switch left in AUTH_HOME.
auth_tmp_leftovers() {
  local path
  for path in "$AUTH_HOME"/.*.tmp.*; do
    if [[ -e "$path" || -L "$path" ]]; then
      printf '%s\n' "${path##*/}"
    fi
  done
}

assert_absent() {
  local name="$1" path="$2"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    pass "$name"
  else
    fail "$name" "unexpected path: $path"
  fi
}

assert_symlink() {
  local name="$1" path="$2" target="$3"
  if [[ -L "$path" ]]; then
    assert_eq "$name" "$target" "$(readlink "$path")"
  else
    fail "$name" "not a symlink: $path"
  fi
}

assert_regular_file() {
  local name="$1" path="$2" content="$3"
  if [[ -f "$path" && ! -L "$path" ]]; then
    assert_eq "$name" "$content" "$(cat "$path")"
  else
    fail "$name" "not a regular file: $path"
  fi
}

# --- auth: usage errors ------------------------------------------------------
auth_reset
auth_cli auth
assert_eq 'auth without a subcommand is a usage error' '2|' "$RC|$OUTPUT"
assert_contains 'auth without a subcommand prints a short usage line' \
  "$STDERR" 'usage: glm-agent auth'
auth_cli auth bogus
assert_eq 'auth with an unknown subcommand is a usage error' '2|' "$RC|$OUTPUT"
assert_contains 'unknown auth subcommand is named' "$STDERR" \
  'unknown auth subcommand: bogus'
assert_contains 'unknown auth subcommand prints a short usage line' \
  "$STDERR" 'usage: glm-agent auth'
assert_not_contains 'auth usage error is not the full help' "$STDERR" 'DESCRIPTION'
auth_cli auth list extra
assert_eq 'auth list accepts no arguments' '2|' "$RC|$OUTPUT"
assert_absent 'auth usage errors create no state' "$AUTH_HOME"

# --- auth: list --------------------------------------------------------------
auth_cli auth list
assert_eq 'auth list without any state reports no accounts' \
  $'0|ACTIVE_ACCOUNT=\nACCOUNT_COUNT=0' "$RC|$OUTPUT"
assert_absent 'auth list creates no state' "$AUTH_HOME"

mkdir -p "$AUTH_HOME/accounts/Zeta" "$AUTH_HOME/accounts/alpha" \
  "$AUTH_HOME/accounts/Beta" "$AUTH_HOME/accounts/.tmp.stale" \
  "$AUTH_HOME/accounts/no-key"
printf '%s\n' "$AUTH_KEY_ME" >"$AUTH_HOME/accounts/Zeta/api-key"
printf '%s\n' "$AUTH_KEY_ACME" >"$AUTH_HOME/accounts/alpha/api-key"
printf '%s\n' "$AUTH_KEY_OTHER" >"$AUTH_HOME/accounts/Beta/api-key"
printf 'organization=%s\nproject=%s\n' "$AUTH_ORG" "$AUTH_PROJ" \
  >"$AUTH_HOME/accounts/Beta/team-scope"
printf '%s\n' "$AUTH_KEY_ME" >"$AUTH_HOME/accounts/.tmp.stale/api-key"
ln -s accounts/alpha/api-key "$AUTH_HOME/.env.auth"
auth_cli auth list
expected_sorted_list="$(cat <<EOF
ACTIVE_ACCOUNT=alpha
ACCOUNT_COUNT=3
ACCOUNT_1_NAME=Beta
ACCOUNT_1_TYPE=team
ACCOUNT_1_ORGANIZATION=$AUTH_ORG
ACCOUNT_1_PROJECT=$AUTH_PROJ
ACCOUNT_1_ACTIVE=false
ACCOUNT_2_NAME=Zeta
ACCOUNT_2_TYPE=personal
ACCOUNT_2_ORGANIZATION=
ACCOUNT_2_PROJECT=
ACCOUNT_2_ACTIVE=false
ACCOUNT_3_NAME=alpha
ACCOUNT_3_TYPE=personal
ACCOUNT_3_ORGANIZATION=
ACCOUNT_3_PROJECT=
ACCOUNT_3_ACTIVE=true
EOF
)"
assert_eq 'auth list sorts accounts in C order and marks the active one' \
  "0|$expected_sorted_list" "$RC|$OUTPUT"

printf 'organization=%s\n' "$AUTH_ORG" >"$AUTH_HOME/accounts/Beta/team-scope"
auth_cli auth list
assert_eq 'auth list rejects a malformed team scope' '2|' "$RC|$OUTPUT"
assert_contains 'malformed scope error names the file' "$STDERR" \
  "$AUTH_HOME/accounts/Beta/team-scope"

# --- auth: migration of the legacy layout ------------------------------------
auth_reset
auth_cli api-key "$AUTH_KEY_LEGACY"
auth_cli auth list
expected_migrated_personal="$(cat <<EOF
MIGRATED_ACCOUNT=personal
ACTIVE_ACCOUNT=personal
ACCOUNT_COUNT=1
ACCOUNT_1_NAME=personal
ACCOUNT_1_TYPE=personal
ACCOUNT_1_ORGANIZATION=
ACCOUNT_1_PROJECT=
ACCOUNT_1_ACTIVE=true
EOF
)"
assert_eq 'a legacy key without a scope migrates to the personal account' \
  "0|$expected_migrated_personal" "$RC|$OUTPUT"
assert_symlink 'migration links .env.auth with a relative target' \
  "$AUTH_HOME/.env.auth" 'accounts/personal/api-key'
assert_regular_file 'migration moves the key into the account' \
  "$AUTH_HOME/accounts/personal/api-key" "$AUTH_KEY_LEGACY"
assert_eq 'the key stays readable through .env.auth' "$AUTH_KEY_LEGACY" \
  "$(cat "$AUTH_HOME/.env.auth")"
assert_absent 'a personal migration leaves no team-scope link' \
  "$AUTH_HOME/.env.team-scope"
assert_absent 'a personal migration leaves no team-scope file' \
  "$AUTH_HOME/accounts/personal/team-scope"
assert_eq 'accounts directory is private' '700' "$(file_mode "$AUTH_HOME/accounts")"
assert_eq 'migrated account directory is private' '700' \
  "$(file_mode "$AUTH_HOME/accounts/personal")"
assert_eq 'migrated key file is private' '600' \
  "$(file_mode "$AUTH_HOME/accounts/personal/api-key")"
assert_eq 'migration leaves only the account in accounts' 'personal' \
  "$(ls -A "$AUTH_HOME/accounts")"
auth_cli auth list
assert_eq 'migration happens once' \
  "0|$(printf '%s\n' "$expected_migrated_personal" | sed '1d')" "$RC|$OUTPUT"

auth_reset
auth_cli api-key "$AUTH_KEY_LEGACY"
auth_cli team-scope "$AUTH_ORG" "$AUTH_PROJ"
auth_cli auth list
expected_migrated_team="$(cat <<EOF
MIGRATED_ACCOUNT=team
ACTIVE_ACCOUNT=team
ACCOUNT_COUNT=1
ACCOUNT_1_NAME=team
ACCOUNT_1_TYPE=team
ACCOUNT_1_ORGANIZATION=$AUTH_ORG
ACCOUNT_1_PROJECT=$AUTH_PROJ
ACCOUNT_1_ACTIVE=true
EOF
)"
assert_eq 'a legacy key with a scope migrates to the team account' \
  "0|$expected_migrated_team" "$RC|$OUTPUT"
assert_symlink 'team migration links .env.auth' \
  "$AUTH_HOME/.env.auth" 'accounts/team/api-key'
assert_symlink 'team migration links .env.team-scope' \
  "$AUTH_HOME/.env.team-scope" 'accounts/team/team-scope'
assert_regular_file 'team migration moves the key' \
  "$AUTH_HOME/accounts/team/api-key" "$AUTH_KEY_LEGACY"
assert_regular_file 'team migration moves the scope' \
  "$AUTH_HOME/accounts/team/team-scope" \
  $'organization='"$AUTH_ORG"$'\nproject='"$AUTH_PROJ"
assert_eq 'migrated team directory is private' '700' \
  "$(file_mode "$AUTH_HOME/accounts/team")"
assert_eq 'migrated team key file is private' '600' \
  "$(file_mode "$AUTH_HOME/accounts/team/api-key")"
assert_eq 'migrated team scope file is private' '600' \
  "$(file_mode "$AUTH_HOME/accounts/team/team-scope")"
auth_cli team-scope
assert_eq 'team-scope shows the scope through the migrated link' \
  $'0|TEAM_SCOPE=team\nORGANIZATION='"$AUTH_ORG"$'\nPROJECT='"$AUTH_PROJ" \
  "$RC|$OUTPUT"

# Refusals move nothing and print nothing on stdout.
auth_reset
auth_cli api-key "$AUTH_KEY_LEGACY"
mkdir -p "$AUTH_HOME/accounts/personal"
auth_cli auth list
assert_eq 'migration refuses when accounts/personal exists' '2|' "$RC|$OUTPUT"
assert_contains 'the personal refusal names the account directory' "$STDERR" \
  "$AUTH_HOME/accounts/personal"
assert_regular_file 'a refused personal migration keeps the legacy key' \
  "$AUTH_HOME/.env.auth" "$AUTH_KEY_LEGACY"
assert_eq 'a refused personal migration moves nothing' '' \
  "$(ls -A "$AUTH_HOME/accounts/personal")"

auth_reset
auth_cli api-key "$AUTH_KEY_LEGACY"
auth_cli team-scope "$AUTH_ORG" "$AUTH_PROJ"
mkdir -p "$AUTH_HOME/accounts/team"
auth_cli auth list
assert_eq 'migration refuses when accounts/team exists' '2|' "$RC|$OUTPUT"
assert_regular_file 'a refused team migration keeps the legacy key' \
  "$AUTH_HOME/.env.auth" "$AUTH_KEY_LEGACY"
assert_regular_file 'a refused team migration keeps the legacy scope' \
  "$AUTH_HOME/.env.team-scope" \
  $'organization='"$AUTH_ORG"$'\nproject='"$AUTH_PROJ"
assert_eq 'a refused team migration moves nothing' '' \
  "$(ls -A "$AUTH_HOME/accounts/team")"

auth_reset
mkdir -p "$AUTH_HOME"
printf 'organization=%s\nproject=%s\n' "$AUTH_ORG" "$AUTH_PROJ" \
  >"$AUTH_HOME/.env.team-scope"
auth_cli auth list
assert_eq 'migration refuses a legacy scope without a legacy key' \
  '2|' "$RC|$OUTPUT"
assert_contains 'the scope-only refusal names the scope file' "$STDERR" \
  "$AUTH_HOME/.env.team-scope"
assert_regular_file 'a scope-only refusal keeps the scope file' \
  "$AUTH_HOME/.env.team-scope" \
  $'organization='"$AUTH_ORG"$'\nproject='"$AUTH_PROJ"
assert_absent 'a scope-only refusal creates no accounts directory' \
  "$AUTH_HOME/accounts"

auth_reset
mkdir -p "$AUTH_HOME"
ln -s accounts/ghost/api-key "$AUTH_HOME/.env.auth"
auth_cli auth list
assert_eq 'migration refuses a dangling .env.auth symlink' '2|' "$RC|$OUTPUT"
assert_contains 'the dangling refusal says so' "$STDERR" 'dangling'
assert_symlink 'a dangling refusal keeps the symlink' \
  "$AUTH_HOME/.env.auth" 'accounts/ghost/api-key'

auth_reset
mkdir -p "$AUTH_HOME"
printf '%s\n' "$AUTH_KEY_LEGACY" >"$TEST_ROOT/foreign-key"
ln -s "$TEST_ROOT/foreign-key" "$AUTH_HOME/.env.auth"
auth_cli auth list
assert_eq 'auth refuses a .env.auth symlink that leaves accounts/' \
  '2|' "$RC|$OUTPUT"
assert_symlink 'a foreign symlink stays untouched' \
  "$AUTH_HOME/.env.auth" "$TEST_ROOT/foreign-key"

auth_reset
auth_cli api-key "$AUTH_KEY_LEGACY"
auth_cli auth bogus
assert_eq 'a usage error does not migrate the legacy layout' '2|' "$RC|$OUTPUT"
assert_regular_file 'the legacy key survives a usage error' \
  "$AUTH_HOME/.env.auth" "$AUTH_KEY_LEGACY"
assert_absent 'a usage error creates no accounts directory' \
  "$AUTH_HOME/accounts"

# Only auth subcommands migrate.
auth_reset
auth_cli api-key "$AUTH_KEY_LEGACY"
auth_quota
assert_eq 'quota still works on the legacy layout' '0' "$RC"
assert_eq 'quota still sends the legacy key' \
  "Authorization: $AUTH_KEY_LEGACY" "$(cat "$FAKE_CURL_STDIN")"
auth_cli team-scope
assert_eq 'team-scope still shows the legacy scope' \
  $'0|TEAM_SCOPE=personal\nORGANIZATION=\nPROJECT=' "$RC|$OUTPUT"
auth_cli api-key "$AUTH_KEY_ROTATED"
assert_eq 'api-key still reports the legacy file' \
  "0|API_KEY=SAVED"$'\n'"AUTH_FILE=$AUTH_HOME/.env.auth" "$RC|$OUTPUT"
assert_regular_file 'commands outside auth keep the legacy key a regular file' \
  "$AUTH_HOME/.env.auth" "$AUTH_KEY_ROTATED"
assert_absent 'commands outside auth create no accounts directory' \
  "$AUTH_HOME/accounts"

# --- auth: add ---------------------------------------------------------------
auth_reset
auth_cli auth add personal --name me --api-key "$AUTH_KEY_ME"
assert_eq 'add personal prints the receipt' \
  $'0|ACCOUNT=ADDED\nNAME=me\nTYPE=personal\nORGANIZATION=\nPROJECT=\nACTIVE=false' \
  "$RC|$OUTPUT"
assert_regular_file 'add personal stores the key' \
  "$AUTH_HOME/accounts/me/api-key" "$AUTH_KEY_ME"
assert_absent 'add personal stores no team scope' \
  "$AUTH_HOME/accounts/me/team-scope"
assert_eq 'add keeps the state home private' '700' "$(file_mode "$AUTH_HOME")"
assert_eq 'add keeps the accounts directory private' '700' \
  "$(file_mode "$AUTH_HOME/accounts")"
assert_eq 'add makes the account directory private' '700' \
  "$(file_mode "$AUTH_HOME/accounts/me")"
assert_eq 'add makes the key file private' '600' \
  "$(file_mode "$AUTH_HOME/accounts/me/api-key")"
assert_eq 'add leaves only the account in accounts' 'me' \
  "$(ls -A "$AUTH_HOME/accounts")"
assert_absent 'add never activates the account' "$AUTH_HOME/.env.auth"
assert_absent 'add personal never links a team scope' \
  "$AUTH_HOME/.env.team-scope"

auth_cli auth add team --project "$AUTH_PROJ" --api-key "$AUTH_KEY_ACME" \
  --organization "$AUTH_ORG" --name acme
assert_eq 'add team prints the receipt and accepts any option order' \
  $'0|ACCOUNT=ADDED\nNAME=acme\nTYPE=team\nORGANIZATION='"$AUTH_ORG"$'\nPROJECT='"$AUTH_PROJ"$'\nACTIVE=false' \
  "$RC|$OUTPUT"
assert_regular_file 'add team stores the key' \
  "$AUTH_HOME/accounts/acme/api-key" "$AUTH_KEY_ACME"
assert_regular_file 'add team stores the two-line scope' \
  "$AUTH_HOME/accounts/acme/team-scope" \
  $'organization='"$AUTH_ORG"$'\nproject='"$AUTH_PROJ"
assert_eq 'add team makes the account directory private' '700' \
  "$(file_mode "$AUTH_HOME/accounts/acme")"
assert_eq 'add team makes the key file private' '600' \
  "$(file_mode "$AUTH_HOME/accounts/acme/api-key")"
assert_eq 'add team makes the scope file private' '600' \
  "$(file_mode "$AUTH_HOME/accounts/acme/team-scope")"

auth_cli auth add personal --api-key "$AUTH_KEY_OTHER" --name me2
assert_contains 'add personal accepts any option order' "$OUTPUT" $'NAME=me2\n'

ln -s accounts/me/api-key "$AUTH_HOME/.env.auth"
auth_cli auth add team --name acme2 --api-key "$AUTH_KEY_OTHER" \
  --organization "$AUTH_ORG" --project "$AUTH_PROJ"
assert_eq 'add keeps another account active' '0|accounts/me/api-key' \
  "$RC|$(readlink "$AUTH_HOME/.env.auth")"
assert_absent 'add never links a team scope while another account is active' \
  "$AUTH_HOME/.env.team-scope"
rm -f -- "$AUTH_HOME/.env.auth"

auth_accounts_expected="$(ls -A "$AUTH_HOME/accounts")"

# assert_auth_add_rejected <label> <stderr-fragment> <auth add args...>
assert_auth_add_rejected() {
  local label="$1" fragment="$2"
  shift 2
  auth_cli auth add "$@"
  assert_eq "$label exits 2 with empty stdout" '2|' "$RC|$OUTPUT"
  assert_contains "$label names the problem" "$STDERR" "$fragment"
  assert_eq "$label creates no account" "$auth_accounts_expected" \
    "$(ls -A "$AUTH_HOME/accounts")"
}

assert_auth_add_rejected 'add without a kind' 'auth add requires a kind'
assert_auth_add_rejected 'add with an unknown kind' \
  'unknown account kind: robot' robot --name x --api-key k
assert_contains 'a kind error prints a short usage line' "$STDERR" \
  'usage: glm-agent auth'

assert_auth_add_rejected 'add personal without a name' \
  'missing required option(s): --name' personal --api-key k
assert_auth_add_rejected 'add personal without a key' \
  'missing required option(s): --api-key' personal --name x
assert_auth_add_rejected 'add personal without any option' \
  'missing required option(s): --name --api-key' personal
assert_auth_add_rejected 'add personal with a repeated name' \
  '--name given more than once' personal --name x --name y --api-key k
assert_auth_add_rejected 'add personal with a repeated key' \
  '--api-key given more than once' personal --name x --api-key k --api-key j
assert_auth_add_rejected 'add personal with --organization' \
  'unknown option for auth add personal: --organization' \
  personal --name x --api-key k --organization o
assert_auth_add_rejected 'add personal with --project' \
  'unknown option for auth add personal: --project' \
  personal --name x --api-key k --project p
assert_auth_add_rejected 'add personal with an unknown option' \
  'unknown option for auth add personal: --force' \
  personal --name x --api-key k --force
assert_auth_add_rejected 'add personal with a positional argument' \
  'accepts no positional arguments: extra' personal --name x --api-key k extra
assert_auth_add_rejected 'add personal with an empty name' \
  '--name must not be empty' personal --name '' --api-key k
assert_auth_add_rejected 'add personal with an empty key' \
  '--api-key must not be empty' personal --name x --api-key ''
assert_auth_add_rejected 'add personal with a trailing option and no value' \
  '--api-key requires a value' personal --name x --api-key
assert_auth_add_rejected 'add personal with an option in place of a value' \
  '--name requires a value' personal --name --api-key k
assert_auth_add_rejected 'add personal with a multi-line key' \
  'API key must be a single line' personal --name x --api-key $'k\nj'

for team_missing in name api-key organization project; do
  team_args=(--name x --api-key k --organization o --project p)
  team_remaining=()
  team_skip=0
  for team_arg in "${team_args[@]}"; do
    if ((team_skip)); then
      team_skip=0
      continue
    fi
    if [[ "$team_arg" == "--$team_missing" ]]; then
      team_skip=1
      continue
    fi
    team_remaining+=("$team_arg")
  done
  assert_auth_add_rejected "add team without --$team_missing" \
    "missing required option(s): --$team_missing" team "${team_remaining[@]}"
done
assert_auth_add_rejected 'add team without any option' \
  'missing required option(s): --name --api-key --organization --project' team
assert_auth_add_rejected 'add team with a repeated organization' \
  '--organization given more than once' \
  team --name x --api-key k --organization o --organization q --project p
assert_auth_add_rejected 'add team with a repeated project' \
  '--project given more than once' \
  team --name x --api-key k --organization o --project p --project q
assert_auth_add_rejected 'add team with an empty organization' \
  '--organization must not be empty' \
  team --name x --api-key k --organization '' --project p
assert_auth_add_rejected 'add team with an empty project' \
  '--project must not be empty' \
  team --name x --api-key k --organization o --project ''
assert_auth_add_rejected 'add team with a multi-line organization' \
  'team organization must be a single line' \
  team --name x --api-key k --organization $'o\nq' --project p
assert_auth_add_rejected 'add team with a multi-line project' \
  'team project must be a single line' \
  team --name x --api-key k --organization o --project $'p\nq'
assert_auth_add_rejected 'add team with an unknown option' \
  'unknown option for auth add team: --force' \
  team --name x --api-key k --organization o --project p --force
assert_auth_add_rejected 'add team with a positional argument' \
  'accepts no positional arguments: extra' \
  team --name x --api-key k --organization o --project p extra

for bad_name in 'bad name' '-lead' '.lead' 'a/b' '..' 'caf'$'\303\251' $'a\nb'; do
  assert_auth_add_rejected "add rejects the account name [${bad_name//$'\n'/\\n}]" \
    'account name' personal --name "$bad_name" --api-key k
done

assert_auth_add_rejected 'add rejects a duplicate personal name' \
  'account already exists: me' personal --name me --api-key "$AUTH_KEY_OTHER"
assert_regular_file 'a duplicate name keeps the stored key' \
  "$AUTH_HOME/accounts/me/api-key" "$AUTH_KEY_ME"
assert_auth_add_rejected 'add rejects a duplicate team name' \
  'account already exists: acme' \
  team --name acme --api-key "$AUTH_KEY_OTHER" --organization o --project p
assert_regular_file 'a duplicate team name keeps the stored scope' \
  "$AUTH_HOME/accounts/acme/team-scope" \
  $'organization='"$AUTH_ORG"$'\nproject='"$AUTH_PROJ"
assert_auth_add_rejected 'add rejects a personal name that exists as a team' \
  'account already exists: acme' \
  personal --name acme --api-key "$AUTH_KEY_OTHER"

# --api-key - reads one line from stdin so the key stays out of argv.
printf '%s\n' "$AUTH_KEY_STDIN" >"$TEST_ROOT/auth-stdin"
{ auth_cli auth add personal --name piped --api-key -; } <"$TEST_ROOT/auth-stdin"
assert_eq 'add reads the key from stdin' \
  $'0|ACCOUNT=ADDED\nNAME=piped\nTYPE=personal\nORGANIZATION=\nPROJECT=\nACTIVE=false' \
  "$RC|$OUTPUT"
assert_regular_file 'the stdin key is stored without its newline' \
  "$AUTH_HOME/accounts/piped/api-key" "$AUTH_KEY_STDIN"

printf '%s' "$AUTH_KEY_STDIN" >"$TEST_ROOT/auth-stdin"
{ auth_cli auth add personal --name piped-bare --api-key -; } \
  <"$TEST_ROOT/auth-stdin"
assert_eq 'add accepts a stdin key without a trailing newline' '0' "$RC"
assert_regular_file 'the unterminated stdin key is stored' \
  "$AUTH_HOME/accounts/piped-bare/api-key" "$AUTH_KEY_STDIN"

printf '%s\n%s\n' "$AUTH_KEY_STDIN" "$AUTH_KEY_OTHER" >"$TEST_ROOT/auth-stdin"
{ auth_cli auth add personal --name piped-first --api-key -; } \
  <"$TEST_ROOT/auth-stdin"
assert_regular_file 'add reads only the first stdin line' \
  "$AUTH_HOME/accounts/piped-first/api-key" "$AUTH_KEY_STDIN"

printf '%s\n' "$AUTH_KEY_STDIN" >"$TEST_ROOT/auth-stdin"
{ auth_cli auth add team --name piped-team --api-key - \
  --organization "$AUTH_ORG" --project "$AUTH_PROJ"; } <"$TEST_ROOT/auth-stdin"
assert_eq 'add team reads the key from stdin' '0' "$RC"
assert_regular_file 'the team stdin key is stored' \
  "$AUTH_HOME/accounts/piped-team/api-key" "$AUTH_KEY_STDIN"

auth_accounts_expected="$(ls -A "$AUTH_HOME/accounts")"
{ assert_auth_add_rejected 'add with an empty stdin' 'stdin' \
  personal --name empty-stdin --api-key -; } </dev/null
printf '\n' >"$TEST_ROOT/auth-stdin"
{ assert_auth_add_rejected 'add with a blank stdin line' 'stdin' \
  personal --name blank-stdin --api-key -; } <"$TEST_ROOT/auth-stdin"
printf 'k\r\n' >"$TEST_ROOT/auth-stdin"
{ assert_auth_add_rejected 'add with a CRLF stdin line' \
  'API key must be a single line' \
  personal --name crlf-stdin --api-key -; } <"$TEST_ROOT/auth-stdin"

# A failing rename removes the temporary directory.
auth_reset
capture env -u ZAI_API_KEY PATH="$quota_mv_bin:$PATH" \
  GLM_AGENT_HOME="$AUTH_HOME" "$SCRIPT" auth add personal --name doomed \
  --api-key "$AUTH_KEY_ME"
AUTH_SEEN+="$OUTPUT"$'\n'"$STDERR"$'\n'
assert_eq 'add with a failing rename exits 2 with empty stdout' '2|' \
  "$RC|$OUTPUT"
assert_contains 'add names the account it could not create' "$STDERR" \
  'cannot create the account: doomed'
assert_eq 'add removes its temporary directory on failure' '' \
  "$(ls -A "$AUTH_HOME/accounts")"

# add runs the legacy migration first and prints its line first.
auth_reset
auth_cli api-key "$AUTH_KEY_LEGACY"
auth_cli auth add personal --name extra --api-key "$AUTH_KEY_ME"
assert_eq 'add prints MIGRATED_ACCOUNT first' \
  $'0|MIGRATED_ACCOUNT=personal\nACCOUNT=ADDED\nNAME=extra\nTYPE=personal\nORGANIZATION=\nPROJECT=\nACTIVE=false' \
  "$RC|$OUTPUT"
assert_symlink 'add after a migration keeps the migrated account active' \
  "$AUTH_HOME/.env.auth" 'accounts/personal/api-key'
auth_cli auth add personal --name personal --api-key "$AUTH_KEY_ME"
assert_eq 'add rejects the name of the migrated account' '2' "$RC"
assert_contains 'the migrated name is reported as taken' "$STDERR" \
  'account already exists: personal'

# --- auth: switch ------------------------------------------------------------
auth_reset
auth_cli auth add personal --name me --api-key "$AUTH_KEY_ME"
auth_cli auth add team --name acme --api-key "$AUTH_KEY_ACME" \
  --organization "$AUTH_ORG" --project "$AUTH_PROJ"
auth_cli auth add team --name other --api-key "$AUTH_KEY_OTHER" \
  --organization "$AUTH_ORG_OTHER" --project "$AUTH_PROJ_OTHER"

auth_cli auth switch me
assert_eq 'switch to a personal account prints the receipt' \
  $'0|ACCOUNT=ACTIVE\nNAME=me\nTYPE=personal' "$RC|$OUTPUT"
assert_symlink 'switch links .env.auth with a relative target' \
  "$AUTH_HOME/.env.auth" 'accounts/me/api-key'
assert_absent 'a personal account has no team-scope link' \
  "$AUTH_HOME/.env.team-scope"
auth_quota
assert_eq 'quota succeeds for the active personal account' '0' "$RC"
assert_contains 'quota reports the personal scope' "$OUTPUT" $'SCOPE=personal\n'
assert_eq 'quota sends the personal key and no selector headers' \
  "Authorization: $AUTH_KEY_ME" "$(cat "$FAKE_CURL_STDIN")"
assert_eq 'the personal lookup has no type=2' \
  'arg=https://api.z.ai/api/monitor/usage/quota/limit' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"

auth_cli auth switch acme
assert_eq 'switch to a team account prints the receipt' \
  $'0|ACCOUNT=ACTIVE\nNAME=acme\nTYPE=team' "$RC|$OUTPUT"
assert_symlink 'switch to a team account links .env.auth' \
  "$AUTH_HOME/.env.auth" 'accounts/acme/api-key'
assert_symlink 'switch to a team account links .env.team-scope' \
  "$AUTH_HOME/.env.team-scope" 'accounts/acme/team-scope'
auth_quota
assert_contains 'quota reports the team scope' "$OUTPUT" $'SCOPE=team\n'
assert_eq 'quota sends the team key and both selector headers' \
  $'Authorization: '"$AUTH_KEY_ACME"$'\nBigmodel-Organization: '"$AUTH_ORG"$'\nBigmodel-Project: '"$AUTH_PROJ" \
  "$(cat "$FAKE_CURL_STDIN")"
assert_eq 'the team lookup uses type=2' \
  'arg=https://api.z.ai/api/monitor/usage/quota/limit?type=2' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"

auth_cli auth switch other
assert_eq 'switch between team accounts repoints both links' \
  "0|accounts/other/api-key|accounts/other/team-scope" \
  "$RC|$(readlink "$AUTH_HOME/.env.auth")|$(readlink "$AUTH_HOME/.env.team-scope")"
auth_quota
assert_eq 'quota follows the second team account' \
  $'Authorization: '"$AUTH_KEY_OTHER"$'\nBigmodel-Organization: '"$AUTH_ORG_OTHER"$'\nBigmodel-Project: '"$AUTH_PROJ_OTHER" \
  "$(cat "$FAKE_CURL_STDIN")"

auth_cli auth switch me
assert_eq 'switch back to a personal account removes the team-scope link' \
  '0|accounts/me/api-key' "$RC|$(readlink "$AUTH_HOME/.env.auth")"
assert_absent 'the team-scope link is gone' "$AUTH_HOME/.env.team-scope"
assert_regular_file 'switching never touches the team-scope file' \
  "$AUTH_HOME/accounts/other/team-scope" \
  $'organization='"$AUTH_ORG_OTHER"$'\nproject='"$AUTH_PROJ_OTHER"
auth_quota
assert_eq 'quota is personal again' "Authorization: $AUTH_KEY_ME" \
  "$(cat "$FAKE_CURL_STDIN")"

auth_cli auth switch me
assert_eq 'switching to the active account succeeds' \
  $'0|ACCOUNT=ACTIVE\nNAME=me\nTYPE=personal' "$RC|$OUTPUT"
auth_cli auth list
assert_contains 'list marks the switched account active' "$OUTPUT" \
  $'ACTIVE_ACCOUNT=me\n'
assert_eq 'switch leaves no temporary link behind' '' \
  "$(auth_tmp_leftovers)"

mkdir -p "$AUTH_HOME/accounts/no-key"
for bad_switch in ghost no-key; do
  auth_cli auth switch "$bad_switch"
  assert_eq "switch to [$bad_switch] exits 2 with empty stdout" '2|' "$RC|$OUTPUT"
  assert_contains "switch to [$bad_switch] says the account is missing" \
    "$STDERR" "account not found: $bad_switch"
done
assert_symlink 'a refused switch keeps the active account' \
  "$AUTH_HOME/.env.auth" 'accounts/me/api-key'
auth_cli auth switch '../escape'
assert_eq 'switch rejects an unsafe account name' '2|' "$RC|$OUTPUT"
assert_contains 'the unsafe name is reported' "$STDERR" 'invalid account name'
auth_cli auth switch
assert_eq 'switch without a name is a usage error' '2|' "$RC|$OUTPUT"
assert_contains 'switch without a name prints a short usage line' "$STDERR" \
  'usage: glm-agent auth'
auth_cli auth switch me acme
assert_eq 'switch with two names is a usage error' '2|' "$RC|$OUTPUT"

# The two links are not swapped in one step: a team target gets its scope link
# first, and a personal target loses its scope link only after .env.auth moved.
auth_real_mv="$(command -v mv)"
auth_mv_bin="$TEST_ROOT/auth-bin-mv-auth-fails"
mkdir -p "$auth_mv_bin"
cat >"$auth_mv_bin/mv" <<EOF
#!/bin/sh
for last; do :; done
case "\$last" in
  */.env.auth) exit 1 ;;
esac
exec "$auth_real_mv" "\$@"
EOF
chmod +x "$auth_mv_bin/mv"

capture env -u ZAI_API_KEY PATH="$auth_mv_bin:$PATH" \
  GLM_AGENT_HOME="$AUTH_HOME" "$SCRIPT" auth switch acme
AUTH_SEEN+="$OUTPUT"$'\n'"$STDERR"$'\n'
assert_eq 'a failing .env.auth swap exits 2 with empty stdout' '2|' "$RC|$OUTPUT"
assert_contains 'the failing swap names the link' "$STDERR" \
  "cannot replace $AUTH_HOME/.env.auth"
assert_eq 'a team switch creates the scope link before swapping .env.auth' \
  'accounts/me/api-key|accounts/acme/team-scope' \
  "$(readlink "$AUTH_HOME/.env.auth")|$(readlink "$AUTH_HOME/.env.team-scope")"
assert_eq 'a failing swap leaves no temporary link behind' '' \
  "$(auth_tmp_leftovers)"

auth_cli auth switch acme
capture env -u ZAI_API_KEY PATH="$auth_mv_bin:$PATH" \
  GLM_AGENT_HOME="$AUTH_HOME" "$SCRIPT" auth switch me
AUTH_SEEN+="$OUTPUT"$'\n'"$STDERR"$'\n'
assert_eq 'a personal switch keeps the scope link until .env.auth moved' \
  "2|accounts/acme/api-key|accounts/acme/team-scope" \
  "$RC|$(readlink "$AUTH_HOME/.env.auth")|$(readlink "$AUTH_HOME/.env.team-scope")"

auth_reset
auth_cli api-key "$AUTH_KEY_LEGACY"
auth_cli auth switch personal
assert_eq 'switch is a migrating subcommand' \
  $'0|MIGRATED_ACCOUNT=personal\nACCOUNT=ACTIVE\nNAME=personal\nTYPE=personal' \
  "$RC|$OUTPUT"

# --- auth: remove ------------------------------------------------------------
auth_reset
auth_cli auth add personal --name me --api-key "$AUTH_KEY_ME"
auth_cli auth add team --name acme --api-key "$AUTH_KEY_ACME" \
  --organization "$AUTH_ORG" --project "$AUTH_PROJ"
auth_cli auth add team --name other --api-key "$AUTH_KEY_OTHER" \
  --organization "$AUTH_ORG_OTHER" --project "$AUTH_PROJ_OTHER"
auth_cli auth switch acme

auth_cli auth remove acme
assert_eq 'remove refuses the active account' '2|' "$RC|$OUTPUT"
assert_contains 'the active refusal tells the user to switch first' "$STDERR" \
  'auth switch'
assert_regular_file 'a refused remove keeps the account' \
  "$AUTH_HOME/accounts/acme/api-key" "$AUTH_KEY_ACME"

auth_cli auth remove ghost
assert_eq 'remove refuses a missing account' '2|' "$RC|$OUTPUT"
assert_contains 'the missing account is named' "$STDERR" \
  'account not found: ghost'
auth_cli auth remove '../escape'
assert_eq 'remove rejects an unsafe account name' '2|' "$RC|$OUTPUT"
auth_cli auth remove
assert_eq 'remove without a name is a usage error' '2|' "$RC|$OUTPUT"
assert_contains 'remove without a name prints a short usage line' "$STDERR" \
  'usage: glm-agent auth'
auth_cli auth remove me other
assert_eq 'remove with two names is a usage error' '2|' "$RC|$OUTPUT"

auth_cli auth remove other
assert_eq 'remove deletes an inactive team account' \
  $'0|ACCOUNT=REMOVED\nNAME=other' "$RC|$OUTPUT"
assert_absent 'remove deletes the account directory' "$AUTH_HOME/accounts/other"
auth_cli auth remove me
assert_eq 'remove deletes an inactive personal account' \
  $'0|ACCOUNT=REMOVED\nNAME=me' "$RC|$OUTPUT"
assert_eq 'remove leaves the active links untouched' \
  'accounts/acme/api-key|accounts/acme/team-scope' \
  "$(readlink "$AUTH_HOME/.env.auth")|$(readlink "$AUTH_HOME/.env.team-scope")"
auth_cli auth list
assert_eq 'list shows only the remaining account' \
  $'ACTIVE_ACCOUNT=acme\nACCOUNT_COUNT=1' \
  "$(printf '%s\n' "$OUTPUT" | sed -n '1,2p')"

auth_reset
auth_cli api-key "$AUTH_KEY_LEGACY"
auth_cli auth remove ghost
assert_eq 'remove after a migration prints MIGRATED_ACCOUNT first' \
  '2|MIGRATED_ACCOUNT=personal' "$RC|$OUTPUT"
auth_cli auth remove personal
assert_eq 'the migrated account is active and cannot be removed' '2|' \
  "$RC|$OUTPUT"

# --- auth: api-key and team-scope under the account layout -------------------
auth_reset
auth_cli auth add personal --name me --api-key "$AUTH_KEY_ME"
auth_cli auth add team --name acme --api-key "$AUTH_KEY_ACME" \
  --organization "$AUTH_ORG" --project "$AUTH_PROJ"
auth_cli auth switch acme

auth_cli api-key "$AUTH_KEY_ROTATED"
assert_eq 'api-key on a managed account reports the account key path' \
  $'0|API_KEY=SAVED\nAUTH_FILE='"$AUTH_HOME/accounts/acme/api-key" "$RC|$OUTPUT"
assert_symlink 'api-key keeps the .env.auth link' \
  "$AUTH_HOME/.env.auth" 'accounts/acme/api-key'
assert_symlink 'api-key keeps the .env.team-scope link' \
  "$AUTH_HOME/.env.team-scope" 'accounts/acme/team-scope'
assert_regular_file 'api-key replaces the key in the account file' \
  "$AUTH_HOME/accounts/acme/api-key" "$AUTH_KEY_ROTATED"
assert_eq 'api-key keeps the account key file private' '600' \
  "$(file_mode "$AUTH_HOME/accounts/acme/api-key")"
assert_eq 'api-key leaves no temporary file in the account' \
  $'api-key\nteam-scope' "$(ls -A "$AUTH_HOME/accounts/acme")"
assert_regular_file 'api-key leaves other accounts alone' \
  "$AUTH_HOME/accounts/me/api-key" "$AUTH_KEY_ME"
auth_quota
assert_eq 'quota sends the replaced key' \
  $'Authorization: '"$AUTH_KEY_ROTATED"$'\nBigmodel-Organization: '"$AUTH_ORG"$'\nBigmodel-Project: '"$AUTH_PROJ" \
  "$(cat "$FAKE_CURL_STDIN")"
if grep -rqF --exclude='api-key' -- "$AUTH_KEY_ROTATED" "$AUTH_HOME"; then
  fail 'only the account key file holds the key' "key found under $AUTH_HOME"
else
  pass 'only the account key file holds the key'
fi

auth_cli team-scope
assert_eq 'team-scope shows the active account scope' \
  $'0|TEAM_SCOPE=team\nORGANIZATION='"$AUTH_ORG"$'\nPROJECT='"$AUTH_PROJ" \
  "$RC|$OUTPUT"
auth_cli team-scope "$AUTH_ORG_OTHER" "$AUTH_PROJ_OTHER"
assert_eq 'team-scope set is refused under a team account' '2|' "$RC|$OUTPUT"
assert_contains 'the set refusal points to auth add team' "$STDERR" \
  'glm-agent auth add team'
auth_cli team-scope --clear
assert_eq 'team-scope --clear is refused under a team account' '2|' \
  "$RC|$OUTPUT"
assert_contains 'the clear refusal points to auth add team' "$STDERR" \
  'glm-agent auth add team'
assert_regular_file 'a refused team-scope keeps the account scope' \
  "$AUTH_HOME/accounts/acme/team-scope" \
  $'organization='"$AUTH_ORG"$'\nproject='"$AUTH_PROJ"
assert_symlink 'a refused team-scope keeps the scope link' \
  "$AUTH_HOME/.env.team-scope" 'accounts/acme/team-scope'

auth_cli auth switch me
auth_cli api-key "$AUTH_KEY_OTHER"
assert_eq 'api-key on a personal account reports the account key path' \
  $'0|API_KEY=SAVED\nAUTH_FILE='"$AUTH_HOME/accounts/me/api-key" "$RC|$OUTPUT"
assert_regular_file 'api-key replaces the personal account key' \
  "$AUTH_HOME/accounts/me/api-key" "$AUTH_KEY_OTHER"
auth_cli team-scope
assert_eq 'team-scope shows the personal scope' \
  $'0|TEAM_SCOPE=personal\nORGANIZATION=\nPROJECT=' "$RC|$OUTPUT"
auth_cli team-scope "$AUTH_ORG" "$AUTH_PROJ"
assert_eq 'team-scope set is refused under a personal account' '2|' \
  "$RC|$OUTPUT"
auth_cli team-scope --clear
assert_eq 'team-scope --clear is refused under a personal account' '2|' \
  "$RC|$OUTPUT"
assert_absent 'a refused team-scope creates no scope link' \
  "$AUTH_HOME/.env.team-scope"

# The environment overrides still apply, and ZAI_API_KEY is still never read.
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 GLM_AGENT_HOME="$AUTH_HOME" \
  ZAI_QUOTA_ORGANIZATION="$AUTH_ORG_OTHER" ZAI_QUOTA_PROJECT="$AUTH_PROJ_OTHER"
AUTH_SEEN+="$OUTPUT"$'\n'"$STDERR"$'\n'
assert_eq 'environment selectors make a personal account query the team plan' \
  $'Authorization: '"$AUTH_KEY_OTHER"$'\nBigmodel-Organization: '"$AUTH_ORG_OTHER"$'\nBigmodel-Project: '"$AUTH_PROJ_OTHER" \
  "$(cat "$FAKE_CURL_STDIN")"
auth_cli auth switch acme
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 GLM_AGENT_HOME="$AUTH_HOME" \
  ZAI_QUOTA_PROJECT="$AUTH_PROJ_OTHER"
AUTH_SEEN+="$OUTPUT"$'\n'"$STDERR"$'\n'
assert_eq 'an environment project overrides only the account project' \
  $'Authorization: '"$AUTH_KEY_ROTATED"$'\nBigmodel-Organization: '"$AUTH_ORG"$'\nBigmodel-Project: '"$AUTH_PROJ_OTHER" \
  "$(cat "$FAKE_CURL_STDIN")"
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 GLM_AGENT_HOME="$AUTH_HOME" \
  ZAI_API_KEY='env-key-ignored-by-accounts'
AUTH_SEEN+="$OUTPUT"$'\n'"$STDERR"$'\n'
assert_contains 'ZAI_API_KEY never replaces the account key' \
  "$(cat "$FAKE_CURL_STDIN")" "Authorization: $AUTH_KEY_ROTATED"

# Accounts without an active one: api-key keeps its legacy behavior.
auth_reset
auth_cli auth add personal --name me --api-key "$AUTH_KEY_ME"
auth_cli api-key "$AUTH_KEY_LEGACY"
assert_eq 'api-key without an active account writes the legacy file' \
  $'0|API_KEY=SAVED\nAUTH_FILE='"$AUTH_HOME/.env.auth" "$RC|$OUTPUT"
assert_regular_file 'the legacy key is a regular file' \
  "$AUTH_HOME/.env.auth" "$AUTH_KEY_LEGACY"
assert_regular_file 'the legacy api-key leaves accounts alone' \
  "$AUTH_HOME/accounts/me/api-key" "$AUTH_KEY_ME"

auth_reset
auth_cli auth add personal --name me --api-key "$AUTH_KEY_ME"
auth_cli run 'diagnostic'
assert_eq 'a missing active account is a configuration error' '2|' \
  "$RC|$OUTPUT"
assert_contains 'the missing key error still names api-key' "$STDERR" \
  'Run: glm-agent api-key'
assert_contains 'the missing key error points to auth add' "$STDERR" \
  'glm-agent auth add'
assert_contains 'the missing key error points to auth switch' "$STDERR" \
  'glm-agent auth switch <name>'

# --- auth: README examples match the CLI output ------------------------------
auth_reset
auth_cli auth add personal --name me --api-key "$AUTH_KEY_ME"
auth_cli auth add team --name acme --api-key "$AUTH_KEY_ACME" \
  --organization '<organization>' --project '<project>'
assert_eq 'README auth add example matches the CLI output' "$OUTPUT" \
  "$(sed -n '/^ACCOUNT=ADDED$/,/^ACTIVE=false$/p' "$REPO_DIR/README.md")"
auth_cli auth switch acme
assert_eq 'README auth switch example matches the CLI output' "$OUTPUT" \
  "$(sed -n '/^ACCOUNT=ACTIVE$/,/^TYPE=team$/p' "$REPO_DIR/README.md")"
auth_cli auth list
assert_eq 'README auth list example matches the CLI output' "$OUTPUT" \
  "$(sed -n '/^ACTIVE_ACCOUNT=/,/^ACCOUNT_2_ACTIVE=/p' "$REPO_DIR/README.md")"
auth_cli auth remove me
assert_eq 'README auth remove example matches the CLI output' "$OUTPUT" \
  "$(sed -n '/^ACCOUNT=REMOVED$/,/^NAME=me$/p' "$REPO_DIR/README.md")"

# --- auth: no key reaches stdout or stderr -----------------------------------
for auth_secret in "$AUTH_KEY_LEGACY" "$AUTH_KEY_ME" "$AUTH_KEY_ACME" \
  "$AUTH_KEY_OTHER" "$AUTH_KEY_STDIN" "$AUTH_KEY_ROTATED"; do
  assert_not_contains "no auth command prints [$auth_secret]" \
    "$AUTH_SEEN" "$auth_secret"
done

touch_days_ago() {
  local path="$1" days="$2" epoch stamp
  epoch="$(( $(date +%s) - days * 86400 ))"
  stamp="$(date -r "$epoch" +%Y%m%d%H%M 2>/dev/null)" ||
    stamp="$(date -d "@$epoch" +%Y%m%d%H%M)"
  touch -t "$stamp" "$path"
}

make_cleanup_worker() {
  local name="$1" status="$2" days="$3" closed="${4:-false}"
  local dir="$GLM_AGENT_HOME/workers/$name"
  mkdir -p "$dir/turns/0001"
  printf 'worker_id=%s\nmodel=sonnet\nrole=general-purpose\ncwd=%s\nclosed=%s\nturn=1\nstatus=%s\nlatest_result=\nerror_kind=\nprovider_code=\n' \
    "$name" "$PROJECT" "$closed" "$status" >"$dir/meta"
  touch_days_ago "$dir/meta" "$days"
}

assert_deleted() {
  if [[ -e "$GLM_AGENT_HOME/workers/$2" ]]; then
    fail "$1" "still present: $2"
  else
    pass "$1"
  fi
}

assert_kept() {
  if [[ -e "$GLM_AGENT_HOME/workers/$2" ]]; then
    pass "$1"
  else
    fail "$1" "deleted: $2"
  fi
}

cleanup_stamp="$GLM_AGENT_HOME/.cleanup-stamp"
cleanup_log_file="$GLM_AGENT_HOME/cleanup.log"
rm -f "$cleanup_log_file" "$cleanup_stamp"

make_cleanup_worker 20250101T000001Z-111-1 DONE 22
make_cleanup_worker 20250101T000002Z-111-2 DONE 20
make_cleanup_worker 20250101T000003Z-111-3 INVALID 22 true
make_cleanup_worker 20250101T000004Z-111-4 NO_REPORT 22
make_cleanup_worker 20250101T000005Z-111-5 BLOCKED 22
make_cleanup_worker 20250101T000006Z-111-6 RUNNING 22
make_cleanup_worker 20250101T000007Z-111-7 NEW 22
mkdir -p "$GLM_AGENT_HOME/workers/20250101T000008Z-111-8/turns"
touch_days_ago "$GLM_AGENT_HOME/workers/20250101T000008Z-111-8" 22
mkdir -p "$GLM_AGENT_HOME/workers/not-a-worker-id/turns"
printf 'status=DONE\n' >"$GLM_AGENT_HOME/workers/not-a-worker-id/meta"
touch_days_ago "$GLM_AGENT_HOME/workers/not-a-worker-id/meta" 22
make_cleanup_worker 20250101T000009Z-111-9 DONE 22
mkdir "$GLM_AGENT_HOME/workers/20250101T000009Z-111-9/active"
cleanup_outside="$TEST_ROOT/outside-worker"
mkdir -p "$cleanup_outside/turns"
printf 'status=DONE\n' >"$cleanup_outside/meta"
touch_days_ago "$cleanup_outside/meta" 22
ln -s "$cleanup_outside" "$GLM_AGENT_HOME/workers/20250101T000020Z-111-20"

capture "$SCRIPT" start --cwd "$PROJECT" 'cleanup trigger'
assert_eq 'a start that cleans up succeeds' '0' "$RC"
assert_eq 'a start that cleans up adds nothing to stderr' '' "$STDERR"
assert_deleted 'cleanup deletes a DONE worker idle for 22 days' 20250101T000001Z-111-1
assert_kept 'cleanup keeps a DONE worker idle for 20 days' 20250101T000002Z-111-2
assert_deleted 'cleanup deletes a closed INVALID worker idle for 22 days' 20250101T000003Z-111-3
assert_deleted 'cleanup deletes a NO_REPORT worker idle for 22 days' 20250101T000004Z-111-4
assert_deleted 'cleanup deletes a BLOCKED worker idle for 22 days' 20250101T000005Z-111-5
assert_kept 'cleanup keeps a RUNNING worker' 20250101T000006Z-111-6
assert_kept 'cleanup keeps a NEW worker' 20250101T000007Z-111-7
assert_kept 'cleanup keeps a directory without meta' 20250101T000008Z-111-8
assert_kept 'cleanup keeps a directory whose name is not a worker id' not-a-worker-id
assert_kept 'cleanup keeps a locked worker' 20250101T000009Z-111-9
assert_file 'cleanup does not follow a symlinked worker directory' "$cleanup_outside/meta"
assert_file 'cleanup writes the stamp file' "$cleanup_stamp"
cleanup_log_text="$(cat "$cleanup_log_file")"
assert_contains 'cleanup logs a deleted worker' "$cleanup_log_text" \
  'deleted worker=20250101T000001Z-111-1 status=DONE idle_days=22'
assert_not_contains 'cleanup does not log a kept worker' "$cleanup_log_text" \
  'worker=20250101T000002Z-111-2'
assert_eq 'cleanup log is private' '600' "$(file_mode "$cleanup_log_file")"
rm -f "$GLM_AGENT_HOME/workers/20250101T000020Z-111-20"

make_cleanup_worker 20250101T000010Z-111-10 DONE 22
capture "$SCRIPT" start --cwd "$PROJECT" 'inside the 24 hour window'
assert_kept 'a start within 24 hours does not clean up' 20250101T000010Z-111-10
touch_days_ago "$cleanup_stamp" 2
capture "$SCRIPT" start --cwd "$PROJECT" 'after the 24 hour window'
assert_deleted 'a start after 24 hours cleans up' 20250101T000010Z-111-10

make_cleanup_worker 20250101T000011Z-111-11 DONE 22
rm -f "$cleanup_stamp"
capture env GLM_WORKER_RETENTION_DAYS=0 "$SCRIPT" start --cwd "$PROJECT" 'cleanup off'
assert_kept 'a retention of 0 days turns the cleanup off' 20250101T000011Z-111-11
if [[ ! -e "$cleanup_stamp" ]]; then
  pass 'a retention of 0 days leaves no stamp'
else
  fail 'a retention of 0 days leaves no stamp' "$cleanup_stamp exists"
fi

capture env GLM_WORKER_RETENTION_DAYS=abc "$SCRIPT" start --cwd "$PROJECT" 'cleanup invalid days'
assert_eq 'an invalid retention does not fail the start' '0' "$RC"
assert_kept 'an invalid retention deletes nothing' 20250101T000011Z-111-11
assert_contains 'an invalid retention logs a warning' "$(cat "$cleanup_log_file")" \
  'warn invalid GLM_WORKER_RETENTION_DAYS=abc'
assert_file 'an invalid retention still writes the stamp' "$cleanup_stamp"

rm -f "$cleanup_stamp"
capture env GLM_WORKER_RETENTION_DAYS=30 "$SCRIPT" start --cwd "$PROJECT" 'retention 30'
assert_kept 'a retention of 30 days keeps a worker idle for 22 days' 20250101T000011Z-111-11
rm -f "$cleanup_stamp"
capture env GLM_WORKER_RETENTION_DAYS=007 "$SCRIPT" start --cwd "$PROJECT" 'retention 007'
assert_deleted 'a retention written as 007 means 7 days' 20250101T000011Z-111-11

make_cleanup_worker 20250101T000012Z-111-12 DONE 22
rm -f "$cleanup_stamp"
capture "$SCRIPT" start --cwd "$PROJECT" 'keys with cleanup'
keys_with_cleanup="$(printf '%s\n' "$OUTPUT" | sed 's/=.*//')"
capture env GLM_WORKER_RETENTION_DAYS=0 "$SCRIPT" start --cwd "$PROJECT" 'keys without cleanup'
keys_without_cleanup="$(printf '%s\n' "$OUTPUT" | sed 's/=.*//')"
assert_eq 'cleanup adds no output line to start' "$keys_without_cleanup" "$keys_with_cleanup"

make_cleanup_worker 20250101T000013Z-111-13 DONE 22
rm -f "$cleanup_stamp" "$cleanup_log_file"
mkdir "$cleanup_log_file"
capture "$SCRIPT" start --cwd "$PROJECT" 'unwritable cleanup log'
assert_eq 'a start succeeds when the cleanup log cannot be written' '0' "$RC"
assert_eq 'an unwritable cleanup log adds nothing to stderr' '' "$STDERR"
assert_deleted 'cleanup still deletes when the log cannot be written' 20250101T000013Z-111-13
rmdir "$cleanup_log_file"

make_cleanup_worker 20250101T000014Z-111-14 DONE 22
rm -f "$cleanup_stamp"
"$SCRIPT" start --cwd "$PROJECT" 'parallel cleanup one' >"$TEST_ROOT/cleanup-parallel-one.out" 2>&1 &
cleanup_pid_one=$!
"$SCRIPT" start --cwd "$PROJECT" 'parallel cleanup two' >"$TEST_ROOT/cleanup-parallel-two.out" 2>&1 &
cleanup_pid_two=$!
if wait "$cleanup_pid_one" && wait "$cleanup_pid_two"; then
  pass 'two parallel starts both succeed while cleaning up'
else
  fail 'two parallel starts both succeed while cleaning up' 'a start failed'
fi
assert_deleted 'parallel starts still delete the old worker' 20250101T000014Z-111-14

printf '1..%d\n' "$tests"
if ((failures > 0)); then
  printf '# %d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '# all %d tests passed\n' "$tests"
