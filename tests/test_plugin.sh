#!/usr/bin/env bash
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
TEST_ROOT="$(mktemp -d "$TEMP_BASE/glm-agent-plugin-test.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

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

assert_file() {
  local name="$1" path="$2"
  if [[ -f "$path" ]]; then
    pass "$name"
  else
    fail "$name" "missing file: $path"
  fi
}

plugin_json="$REPO_DIR/.claude-plugin/plugin.json"
marketplace_json="$REPO_DIR/.claude-plugin/marketplace.json"
explorer_agent="$REPO_DIR/agents/explorer.md"
general_agent="$REPO_DIR/agents/general-purpose.md"

assert_file 'plugin manifest exists' "$plugin_json"
assert_file 'marketplace manifest exists' "$marketplace_json"
assert_file 'explorer agent exists' "$explorer_agent"
assert_file 'general-purpose agent exists' "$general_agent"

if [[ -f "$plugin_json" ]]; then
  assert_eq 'plugin name' 'glm-agent' "$(jq -r '.name' "$plugin_json")"
fi
if [[ -f "$marketplace_json" ]]; then
  assert_eq 'marketplace source' './' \
    "$(jq -r '.plugins[] | select(.name == "glm-agent") | .source' \
      "$marketplace_json")"
fi
if [[ -f "$explorer_agent" ]]; then
  explorer_content="$(cat "$explorer_agent")"
  assert_contains 'explorer uses plugin-root CLI' "$explorer_content" \
    "\${CLAUDE_PLUGIN_ROOT}/glm-agent"
  assert_contains 'explorer does not own worktrees' "$explorer_content" \
    'Never create, switch, or delete a worktree.'
fi
if [[ -f "$general_agent" ]]; then
  general_content="$(cat "$general_agent")"
  general_flat="$(printf '%s' "$general_content" | tr '\n' ' ' | \
    sed -E 's/[[:space:]]+/ /g')"
  assert_contains 'general agent never auto-closes' "$general_flat" \
    'Never close a worker merely because a turn returned DONE or BLOCKED.'
fi

if command -v claude >/dev/null 2>&1 &&
   [[ -f "$plugin_json" && -f "$marketplace_json" &&
      -f "$explorer_agent" && -f "$general_agent" ]]; then
  fixture="$TEST_ROOT/plugin fixture"
  mkdir -p "$fixture"
  cp -R "$REPO_DIR/." "$fixture/"
  if validation_output="$(claude plugin validate --strict "$fixture" 2>&1)"; then
    pass 'Claude validates plugin from a path containing spaces'
  else
    fail 'Claude validates plugin from a path containing spaces' "$validation_output"
  fi
fi

printf '1..%d\n' "$tests"
if ((failures > 0)); then
  printf '# %d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '# all %d tests passed\n' "$tests"
