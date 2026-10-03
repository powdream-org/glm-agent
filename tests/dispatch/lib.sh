#!/usr/bin/env bash
set -Eeuo pipefail

DT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$DT_DIR/../.." && pwd -P)"
DISPATCH="$REPO_DIR/scripts/glm-dispatch"
REAL_CLI="$REPO_DIR/glm-agent"
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
TEST_ROOT="$(mktemp -d "$TEMP_BASE/glm-dispatch-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_CLI_DIR="$TEST_ROOT/fake-cli"
PROJECT="$TEST_ROOT/project"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$FAKE_CLI_DIR" "$PROJECT" "$TEST_ROOT/home"
ln -s "$BASH" "$FAKE_BIN/bash"

cat >"$FAKE_BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail

prompt="${*: -1}"
resume_id=""
while (($#)); do
  case "$1" in
    --resume)
      resume_id="$2"
      shift 2
      ;;
    --model|--append-system-prompt|--output-format)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -n "${FAKE_CLAUDE_PROMPT_FILE:-}" ]]; then
  printf '%s' "$prompt" >"$FAKE_CLAUDE_PROMPT_FILE"
fi
if [[ -z "${GLM_RESULT_FILE:-}" ]]; then
  printf '%s\n' 'RUN_OK'
  exit 0
fi
turn_dir="$(dirname "$GLM_RESULT_FILE")"

if [[ "$prompt" == *WAIT_FOR_RELEASE* ]]; then
  : >"$FAKE_CLAUDE_BLOCK_STARTED"
  ticks=0
  while [[ ! -f "$FAKE_CLAUDE_BLOCK_RELEASE" ]]; do
    [[ -f "$FAKE_CLAUDE_BLOCK_STARTED" ]] || exit 19
    ticks=$((ticks + 1))
    ((ticks < 1200)) || exit 18
    if [[ "$prompt" == *PROGRESS_WHILE_BLOCKED* ]]; then
      printf '%s\n' "$ticks" >>"$turn_dir/progress.log"
    fi
    sleep 0.1
  done
fi

if [[ "$prompt" == *CLAUDE_FAIL* ]]; then
  printf '%s\n' 'simulated claude failure' >&2
  exit 17
fi
if [[ "$prompt" =~ ZAI_ERROR_([0-9]+) ]]; then
  printf '{"error":{"code":"%s","message":"simulated provider error"}}\n' \
    "${BASH_REMATCH[1]}" >&2
  exit 1
fi
if [[ "$prompt" == *TOUCH_TRACKED* ]]; then
  printf 'changed\n' >>tracked.txt
fi
if [[ "$prompt" == *CREATE_FILE* ]]; then
  printf 'new\n' >created.txt
fi
if [[ "$prompt" == *COMMIT_CHANGE* ]]; then
  printf 'committed\n' >committed.txt
  git add committed.txt
  git commit -q -m 'worker commit'
fi

case "$prompt" in
  *MISSING_RESULT*)
    ;;
  *MALFORMED_RESULT*)
    printf '# Summary\nMalformed result\n\nSTATUS: MAYBE\n' >"$GLM_RESULT_FILE"
    ;;
  *RETURN_BLOCKED*)
    printf '# Summary\nBlocked as requested\n\n# Remaining Issues\nNEEDS-MAIN: decide\n\nSTATUS: BLOCKED\n' \
      >"$GLM_RESULT_FILE"
    ;;
  *LONG_SECTIONS*)
    {
      printf '# Summary\n'
      for n in {1..25}; do printf 'summary line %d\n' "$n"; done
      printf '\n# Changes\nNone\n\n# Remaining Issues\n'
      for n in {1..22}; do printf 'issue line %d\n' "$n"; done
      printf '\nSTATUS: DONE\n'
    } >"$GLM_RESULT_FILE"
    ;;
  *)
    printf '# Summary\nCompleted by fake worker\n\n# Changes\nNone\n\n# Remaining Issues\nNone\n\nSTATUS: DONE\n' \
      >"$GLM_RESULT_FILE"
    ;;
esac

printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","result":"ok"}\n' \
  "${resume_id:-session-1}"
FAKE
chmod +x "$FAKE_BIN/claude"

cat >"$FAKE_BIN/curl" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail

output=""
while (($# > 0)); do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -H|-w|--connect-timeout|--max-time)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cat >/dev/null
if [[ -n "${FAKE_CURL_BODY_FILE:-}" ]]; then
  cp "$FAKE_CURL_BODY_FILE" "$output"
fi
printf '%s' "${FAKE_CURL_STATUS:-200}"
exit "${FAKE_CURL_EXIT:-0}"
FAKE
chmod +x "$FAKE_BIN/curl"

cat >"$FAKE_BIN/fake-cli" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail

dir="${FAKE_CLI_DIR:?}"
sub="${1:-}"
count=0
if [[ -f "$dir/$sub.count" ]]; then
  count="$(<"$dir/$sub.count")"
fi
count=$((count + 1))
printf '%s' "$count" >"$dir/$sub.count"
{
  printf 'call=%s\n' "$count"
  for arg in "$@"; do
    printf 'arg=%s\n' "$arg"
  done
} >>"$dir/$sub.argv"
file="$dir/$sub.out.$count"
if [[ ! -f "$file" ]]; then
  file="$dir/$sub.out"
fi
if [[ -f "$file" ]]; then
  cat "$file"
fi
rc=0
if [[ -f "$dir/$sub.rc.$count" ]]; then
  rc="$(<"$dir/$sub.rc.$count")"
elif [[ -f "$dir/$sub.rc" ]]; then
  rc="$(<"$dir/$sub.rc")"
fi
exit "$rc"
FAKE
chmod +x "$FAKE_BIN/fake-cli"

cat >"$FAKE_BIN/spy-cli" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail

rc=0
out="$("${SPY_REAL_CLI:?}" "$@")" || rc=$?
printf '%s\n' "$out"
if [[ "${1:-}" == wait ]]; then
  printf '%s\n' "$out" | sed -n 's/^WAIT_RESULT=//p' >>"${SPY_LOG:?}"
fi
exit "$rc"
FAKE
chmod +x "$FAKE_BIN/spy-cli"

export PATH="$FAKE_BIN:/opt/homebrew/bin:/usr/bin:/bin"
export HOME="$TEST_ROOT/home"
export GLM_AGENT_HOME="$TEST_ROOT/home/.glm"
export FAKE_CLI_DIR
export CLAUDECODE=1
export FAKE_CLAUDE_PROMPT_FILE="$TEST_ROOT/claude.prompt"
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.invalid
export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.invalid
export GIT_CONFIG_NOSYSTEM=1
unset GLM_DISPATCH_CLI ZAI_API_KEY ZAI_QUOTA_ORGANIZATION ZAI_QUOTA_PROJECT

mkdir -p "$GLM_AGENT_HOME"
chmod 700 "$GLM_AGENT_HOME"
printf '%s\n' 'zk-dispatch-test-0123456789abcdef' >"$GLM_AGENT_HOME/.env.auth"
chmod 600 "$GLM_AGENT_HOME/.env.auth"
PROJECT="$(cd "$PROJECT" && pwd -P)"

QUOTA_OK_BODY="$TEST_ROOT/quota-ok.json"
cat >"$QUOTA_OK_BODY" <<'JSON'
{"code":200,"msg":"ok","data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":35000,"currentValue":2789,"remaining":32211,"percentage":7,"nextResetTime":1790791395020},{"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":155000,"currentValue":37560,"remaining":117440,"percentage":24,"nextResetTime":1791162764983}],"level":"max"},"success":true}
JSON
export FAKE_CURL_BODY_FILE="$QUOTA_OK_BODY"

failures=0
tests=0
export SESSION_N=0 SESSION="" BRIEF="" OUTPUT="" STDERR="" RC=0

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

assert_no_file() {
  local name="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    pass "$name"
  else
    fail "$name" "unexpected path: $path"
  fi
}

finish() {
  printf '1..%d\n' "$tests"
  if ((failures > 0)); then
    printf '# %d test(s) failed\n' "$failures" >&2
    exit 1
  fi
  printf '# all %d tests passed\n' "$tests"
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

dispatch() {
  capture "$BASH" "$DISPATCH" "$@"
}

next_session() {
  SESSION_N=$((SESSION_N + 1))
  SESSION="s$SESSION_N"
}

make_brief() {
  BRIEF="$TEST_ROOT/$1"
  printf '%s' "$2" >"$BRIEF"
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

kv_file_get() {
  sed -n "s/^$2=//p" "$1" | head -n 1
}

use_real_cli() {
  unset GLM_DISPATCH_CLI
}

use_fake_cli() {
  local stale
  export GLM_DISPATCH_CLI="$FAKE_BIN/fake-cli"
  for stale in "$FAKE_CLI_DIR"/*; do
    rm -f "$stale"
  done
}

use_spy_cli() {
  export SPY_REAL_CLI="$REAL_CLI"
  export SPY_LOG="$TEST_ROOT/spy.log"
  : >"$SPY_LOG"
  export GLM_DISPATCH_CLI="$FAKE_BIN/spy-cli"
}

fake_cli_set() {
  printf '%s\n' "$2" >"$FAKE_CLI_DIR/$1.out"
  printf '%s' "${3:-0}" >"$FAKE_CLI_DIR/$1.rc"
}

fake_cli_seq() {
  printf '%s\n' "$3" >"$FAKE_CLI_DIR/$1.out.$2"
}

fake_cli_calls() {
  local count_file="$FAKE_CLI_DIR/$1.count"
  if [[ -f "$count_file" ]]; then
    cat "$count_file"
  else
    printf '0'
  fi
}

new_block() {
  export FAKE_CLAUDE_BLOCK_STARTED="$TEST_ROOT/$1.started"
  export FAKE_CLAUDE_BLOCK_RELEASE="$TEST_ROOT/$1.release"
  rm -f "$FAKE_CLAUDE_BLOCK_STARTED" "$FAKE_CLAUDE_BLOCK_RELEASE"
}

release_block() {
  : >"$FAKE_CLAUDE_BLOCK_RELEASE"
}

wait_for_file() {
  local i
  for ((i = 0; i < 1000; i++)); do
    if [[ -f "$1" ]]; then
      return 0
    fi
    sleep 0.02
  done
  return 1
}

make_git_project() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf 'base\n' >"$dir/tracked.txt"
  git -C "$dir" add tracked.txt
  git -C "$dir" commit -q -m init
}
