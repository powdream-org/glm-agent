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
bump_script="$REPO_DIR/scripts/bump-version.sh"
readme="$(cat "$REPO_DIR/README.md")"

assert_file 'plugin manifest exists' "$plugin_json"
assert_file 'marketplace manifest exists' "$marketplace_json"
assert_file 'explorer agent exists' "$explorer_agent"
assert_file 'general-purpose agent exists' "$general_agent"
assert_file 'version bump script exists' "$bump_script"
assert_contains 'README documents marketplace add' "$readme" \
  'claude plugin marketplace add powdream-org/glm-agent'
assert_contains 'README documents plugin install' "$readme" \
  'claude plugin install glm-agent@glm-agent'
assert_contains 'README documents both agents' "$readme" \
  'glm-agent:explorer'
assert_contains 'README documents general agent' "$readme" \
  'glm-agent:general-purpose'
assert_contains 'README documents native connector routing' "$readme" \
  'connector/MCP'

if [[ -f "$plugin_json" ]]; then
  assert_eq 'plugin name' 'glm-agent' "$(jq -r '.name' "$plugin_json")"
fi
if [[ -f "$marketplace_json" ]]; then
  assert_eq 'marketplace source' './' \
    "$(jq -r '.plugins[] | select(.name == "glm-agent") | .source' \
      "$marketplace_json")"
fi

if [[ -f "$plugin_json" && -f "$marketplace_json" ]]; then
  cli_version="$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$REPO_DIR/glm-agent")"
  plugin_version="$(jq -r '.version' "$plugin_json")"
  marketplace_version="$(jq -r \
    '.plugins[] | select(.name == "glm-agent") | .version' \
    "$marketplace_json")"
  assert_eq 'CLI and plugin versions match' "$cli_version" "$plugin_version"
  assert_eq 'CLI and marketplace versions match' "$cli_version" \
    "$marketplace_version"
  assert_eq 'release version is 0.3.0' '0.3.0' "$cli_version"
fi
if [[ -f "$explorer_agent" ]]; then
  explorer_content="$(cat "$explorer_agent")"
  explorer_frontmatter="$(sed -n '2,/^---$/p' "$explorer_agent")"
  explorer_flat="$(printf '%s' "$explorer_content" | tr '\n' ' ' | \
    sed -E 's/[[:space:]]+/ /g')"
  assert_contains 'explorer uses plugin-root CLI' "$explorer_content" \
    "\${CLAUDE_PLUGIN_ROOT}/glm-agent"
  assert_contains 'explorer leaves worktrees with the parent' \
    "$explorer_flat" 'The parent performs all worktree operations.'
  assert_contains 'explorer routes unsupported GLM models to invalid request' \
    "$explorer_flat" \
    'Complete every other GLM_MODEL value with BRIDGE_STATUS=INVALID_REQUEST.'
  assert_contains 'explorer interpreter uses native Sonnet' \
    "$explorer_frontmatter" 'model: sonnet'
  assert_contains 'explorer keeps Bash and Read tools' \
    "$explorer_frontmatter" 'tools: Bash, Read'
  assert_contains 'explorer sends TASK unchanged to GLM' "$explorer_flat" \
    'Pass TASK unchanged as the final CLI argument.'
  assert_contains 'explorer uses one CLI Bash call' "$explorer_flat" \
    'Execute the selected CLI command through one Bash tool call.'
  assert_contains 'explorer returns routing evidence' "$explorer_flat" \
    'Return the CLI control fields as routing evidence.'
  assert_contains 'explorer defines invalid request destination' \
    "$explorer_content" 'BRIDGE_STATUS=INVALID_REQUEST'
fi

if [[ -x "$bump_script" ]]; then
  fixture="$TEST_ROOT/version fixture"
  mkdir -p "$fixture"
  cp -R "$REPO_DIR/." "$fixture/"
  "$fixture/scripts/bump-version.sh" 0.2.1
  assert_eq 'bump updates CLI' 'glm-agent 0.2.1' \
    "$("$fixture/glm-agent" --version)"
  assert_eq 'bump updates plugin manifest' '0.2.1' \
    "$(jq -r '.version' "$fixture/.claude-plugin/plugin.json")"
  assert_eq 'bump updates marketplace' '0.2.1' \
    "$(jq -r '.plugins[0].version' \
      "$fixture/.claude-plugin/marketplace.json")"

  invalid_fixture="$TEST_ROOT/invalid version fixture"
  mkdir -p "$invalid_fixture"
  cp -R "$REPO_DIR/." "$invalid_fixture/"
  before_versions="$(cksum \
    "$invalid_fixture/glm-agent" \
    "$invalid_fixture/.claude-plugin/plugin.json" \
    "$invalid_fixture/.claude-plugin/marketplace.json")"
  for invalid_version in '1.2' 'v1.2.3'; do
    if "$invalid_fixture/scripts/bump-version.sh" "$invalid_version" \
      >"$TEST_ROOT/invalid.out" 2>"$TEST_ROOT/invalid.err"; then
      fail "invalid version $invalid_version is rejected" 'command succeeded'
    else
      pass "invalid version $invalid_version is rejected"
    fi
  done
  if "$invalid_fixture/scripts/bump-version.sh" \
    >"$TEST_ROOT/empty.out" 2>"$TEST_ROOT/empty.err"; then
    fail 'empty version is rejected' 'command succeeded'
  else
    pass 'empty version is rejected'
  fi
  after_versions="$(cksum \
    "$invalid_fixture/glm-agent" \
    "$invalid_fixture/.claude-plugin/plugin.json" \
    "$invalid_fixture/.claude-plugin/marketplace.json")"
  assert_eq 'invalid versions do not change files' "$before_versions" \
    "$after_versions"
fi
if [[ -f "$general_agent" ]]; then
  general_content="$(cat "$general_agent")"
  general_frontmatter="$(sed -n '2,/^---$/p' "$general_agent")"
  general_flat="$(printf '%s' "$general_content" | tr '\n' ' ' | \
    sed -E 's/[[:space:]]+/ /g')"
  assert_contains 'general agent keeps completed workers available' \
    "$general_flat" \
    'Keep the worker available after DONE or BLOCKED and close it for ACTION=close.'
  assert_contains 'general agent routes unsupported GLM models to invalid request' \
    "$general_flat" \
    'Complete every other GLM_MODEL value with BRIDGE_STATUS=INVALID_REQUEST.'
  assert_contains 'general interpreter uses native Sonnet' \
    "$general_frontmatter" 'model: sonnet'
  assert_contains 'general agent keeps Bash and Read tools' \
    "$general_frontmatter" 'tools: Bash, Read'
  assert_contains 'general agent sends TASK unchanged to GLM' \
    "$general_flat" 'Pass TASK unchanged as the final CLI argument.'
  assert_contains 'general agent uses one CLI Bash call' "$general_flat" \
    'Execute the selected CLI command through one Bash tool call.'
  assert_contains 'general agent returns routing evidence' "$general_flat" \
    'Return the CLI control fields as routing evidence.'
  assert_contains 'general agent defines invalid request destination' \
    "$general_content" 'BRIDGE_STATUS=INVALID_REQUEST'
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
