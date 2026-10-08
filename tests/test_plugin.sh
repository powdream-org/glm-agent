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
assert_contains 'README documents managed TUI' "$readme" 'glm-agent tui'
assert_contains 'README documents async start' "$readme" \
  'glm-agent start --async'
assert_contains 'README documents bounded wait' "$readme" \
  'glm-agent wait --timeout'
assert_contains 'README documents cancellation' "$readme" \
  'glm-agent cancel'
assert_contains 'README distinguishes parent stop from cancel' "$readme" \
  'Stopping the parent Claude Code turn does not cancel'
assert_contains 'README documents the quota command' "$readme" \
  'glm-agent quota'
assert_contains 'README documents the quota skill' "$readme" \
  'glm-agent:quota'
assert_contains 'README documents the 5-hour threshold' "$readme" \
  'USED_PERCENT>=90'
assert_contains 'README documents the weekly threshold' "$readme" \
  'USED_PERCENT>=98'
assert_contains 'README documents quota fail-open' "$readme" 'fail-open'
assert_contains 'README explains when WINDOW is empty' "$readme" \
  'is not numeric'
assert_contains 'README blocks on a remainder that is a number <= 0' \
  "$readme" 'is a number ≤ 0'
assert_contains 'README treats an unexpected exit like a setup error' \
  "$readme" 'any exit status other than 0 or 1'
assert_contains 'README latches an exhausted limit with no reset time' \
  "$readme" "empty \`RESET_AT\`"
assert_contains 'README recognises exactly two windows' "$readme" \
  "exactly \`5h\` and \`1w\`"
assert_contains 'README documents the stdin header' "$readme" \
  'curl -H @-'
assert_contains 'AGENTS.md lists the skills directory' \
  "$(cat "$REPO_DIR/AGENTS.md")" 'skills/quota/SKILL.md'
agents_md="$(cat "$REPO_DIR/AGENTS.md")"
assert_contains 'README documents the glm-dispatch script' "$readme" 'glm-dispatch'
assert_contains 'README documents the dispatch skill' "$readme" 'glm-agent:dispatch'
assert_contains 'README has a Dispatch section' "$readme" $'\n## Dispatch\n'
assert_contains 'README recommends glm-dispatch from the main session' "$readme" \
  'is the recommended path'
assert_contains 'README marks the bridge agents as not recommended' "$readme" \
  'bridge agents are not recommended'
for line_name in GLM_BLOCKED GLM_NOT_REACHED GLM_RECEIPT GLM_VERDICT GLM_WARN \
  GLM_STALLED GLM_STILL_RUNNING; do
  assert_contains "README documents $line_name" "$readme" "$line_name"
done
for subcommand in run send attach pending ack status result cancel close; do
  assert_contains "README lists the $subcommand subcommand" "$readme" "| \`$subcommand\` |"
done
for exit_code in 10 11 12 13; do
  assert_contains "README documents dispatch exit code $exit_code" "$readme" "| $exit_code |"
done
for option in --task-file --max-wait --stall-timeout --poll-seconds --allow-path \
  --est-credits --small; do
  assert_contains "README documents the dispatch option $option" "$readme" "$option"
done
for layout_entry in scripts/glm-dispatch 'scripts/lib/dispatch-' tests/test_dispatch.sh \
  tests/dispatch/ skills/dispatch/SKILL.md 'bash tests/test_dispatch.sh'; do
  assert_contains "AGENTS.md mentions $layout_entry" "$agents_md" "$layout_entry"
done
for auth_phrase in 'glm-agent auth add personal --name' \
  'glm-agent auth add team --name' 'glm-agent auth switch' \
  'glm-agent auth remove' 'glm-agent auth list' '--api-key -' \
  'MIGRATED_ACCOUNT' \
  'https://z.ai/manage-apikey/coding-plan/team/usage-stats' \
  'api/monitor/usage/quota/limit' 'Bigmodel-Organization' \
  'Bigmodel-Project' 'one atomic step' \
  'uses the account that is active at that moment'; do
  assert_contains "README documents $auth_phrase" "$readme" "$auth_phrase"
done
for auth_row in "| \`auth add personal --name <name> --api-key <key>\` |" \
  "| \`auth add team --name <name> --api-key <key> --organization <org> --project <project>\` |" \
  "| \`auth switch <name>\` |" "| \`auth remove <name>\` |" "| \`auth list\` |"; do
  assert_contains "README command reference lists $auth_row" "$readme" "$auth_row"
done
assert_contains 'AGENTS.md describes the account directory' "$agents_md" \
  '.glm/accounts/<name>/'
assert_contains 'AGENTS.md describes the .env.auth symlink' "$agents_md" \
  ".glm/.env.auth\` is a relative symlink"
assert_contains 'AGENTS.md keeps the ZAI_API_KEY rule' "$agents_md" \
  "the \`ZAI_API_KEY\` environment"

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
  if [[ "$cli_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    cli_version_format='valid'
  else
    cli_version_format='invalid'
  fi
  assert_eq 'release version is major.minor.patch' 'valid' "$cli_version_format"
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
  assert_contains 'explorer starts workers asynchronously' "$explorer_flat" \
    'start --async --role explorer'
  assert_contains 'explorer sends turns asynchronously' "$explorer_flat" \
    "send --async \"\$WORKER_ID\" \"\$TASK\""
  assert_contains 'explorer waits with a bounded timeout' "$explorer_flat" \
    "wait --timeout 20 \"\$WORKER_ID\""
  assert_contains 'explorer routes cancellation' "$explorer_flat" \
    "cancel \"\$WORKER_ID\""
  assert_contains 'explorer defines launch completion' "$explorer_flat" \
    'start and send reach their destination when the CLI returns WORKER_ID, TURN, and STATUS=RUNNING.'
  assert_contains 'explorer distinguishes semantic completion' "$explorer_flat" \
    'Semantic completion comes from a later wait or status response with STATUS=DONE or STATUS=BLOCKED.'
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
  assert_contains 'general agent starts workers asynchronously' "$general_flat" \
    'start --async --role general-purpose'
  assert_contains 'general agent sends turns asynchronously' "$general_flat" \
    "send --async \"\$WORKER_ID\" \"\$TASK\""
  assert_contains 'general agent waits with a bounded timeout' "$general_flat" \
    "wait --timeout 20 \"\$WORKER_ID\""
  assert_contains 'general agent routes cancellation' "$general_flat" \
    "cancel \"\$WORKER_ID\""
  assert_contains 'general agent defines launch completion' "$general_flat" \
    'start and send reach their destination when the CLI returns WORKER_ID, TURN, and STATUS=RUNNING.'
  assert_contains 'general agent distinguishes semantic completion' "$general_flat" \
    'Semantic completion comes from a later wait or status response with STATUS=DONE or STATUS=BLOCKED.'
  assert_contains 'general agent defines invalid request destination' \
    "$general_content" 'BRIDGE_STATUS=INVALID_REQUEST'
fi

quota_skill="$REPO_DIR/skills/quota/SKILL.md"
assert_file 'quota skill exists' "$quota_skill"
if [[ -f "$quota_skill" ]]; then
  skill_frontmatter="$(sed -n '2,/^---$/p' "$quota_skill")"
  skill_body="$(sed '1,/^---$/d' "$quota_skill")"
  skill_allowed="$(printf '%s\n' "$skill_frontmatter" |
    sed -n 's/^allowed-tools: //p')"
  skill_rule_command="${skill_allowed#Bash(}"
  skill_rule_command="${skill_rule_command%)}"
  assert_eq 'quota skill name' 'quota' \
    "$(printf '%s\n' "$skill_frontmatter" | sed -n 's/^name: //p')"
  assert_eq 'quota skill description' \
    'Use before dispatching work to glm-agent:explorer or glm-agent:general-purpose, and before returning to GLM after a quota-exhausted fallback, to read the remaining Z.ai GLM Coding Plan quota and choose between a GLM worker and native Claude.' \
    "$(printf '%s\n' "$skill_frontmatter" | sed -n 's/^description: //p')"
  assert_eq 'quota skill allows exactly the quota command' \
    "Bash(bash \"\${CLAUDE_PLUGIN_ROOT}/glm-agent\" quota)" "$skill_allowed"
  assert_contains 'quota skill body runs the allowed command' \
    "$skill_body" "$skill_rule_command"
  for keyword in QUOTA_STATUS authentication quota-exhausted fail-open \
    'REMAINING=0' RESET_AT USED_PERCENT 'USED_PERCENT>=90' \
    'USED_PERCENT>=98' TIME_LIMIT '≤ 0' "exactly \`5h\` and \`1w\`" \
    'a status other than 0 or 1' "prints no \`QUOTA_STATUS\` line" \
    "empty \`RESET_AT\`, latch for the current orchestration session"; do
    assert_contains "quota skill decision table mentions $keyword" \
      "$skill_body" "$keyword"
  done
  assert_contains 'quota skill ties the scope to the active account' \
    "$skill_body" 'the active account'
fi

dispatch_skill="$REPO_DIR/skills/dispatch/SKILL.md"
quota_rows="$REPO_DIR/tests/dispatch/quota-rows.tsv"
assert_file 'dispatch skill exists' "$dispatch_skill"
assert_file 'quota rows table exists' "$quota_rows"
if [[ -f "$dispatch_skill" ]]; then
  dispatch_frontmatter="$(sed -n '2,/^---$/p' "$dispatch_skill")"
  dispatch_body="$(sed '1,/^---$/d' "$dispatch_skill")"
  dispatch_allowed="$(printf '%s\n' "$dispatch_frontmatter" |
    sed -n 's/^allowed-tools: //p')"
  dispatch_description="$(printf '%s\n' "$dispatch_frontmatter" |
    sed -n 's/^description: //p')"
  assert_eq 'dispatch skill name' 'dispatch' \
    "$(printf '%s\n' "$dispatch_frontmatter" | sed -n 's/^name: //p')"
  if [[ -n "$dispatch_description" ]]; then
    pass 'dispatch skill description is not empty'
  else
    fail 'dispatch skill description is not empty' 'description line is empty'
  fi
  assert_eq 'dispatch skill allows exactly the glm-dispatch command' \
    "Bash(bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/glm-dispatch\" *)" "$dispatch_allowed"
  assert_contains 'dispatch skill body runs the allowed command' \
    "$dispatch_body" "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/glm-dispatch\""
  for keyword in GLM_BLOCKED GLM_NOT_REACHED GLM_RECEIPT GLM_VERDICT \
    GLM_STALLED GLM_STILL_RUNNING GLM_WARN --wait --max-wait --stall-timeout \
    --task-file --session "\${CLAUDE_SESSION_ID}" run_in_background \
    'timeout: 7200000' CronCreate pending attach worker-protocol NO_REPORT quota-exhausted; do
    assert_contains "dispatch skill body mentions $keyword" "$dispatch_body" "$keyword"
  done
  assert_contains 'dispatch skill forbids opening the account files' \
    "$dispatch_body" '.glm/accounts/'
  if [[ -f "$quota_rows" ]]; then
    while IFS=$'\t' read -r row keyword; do
      assert_contains "dispatch skill decision table row $row mentions $keyword" \
        "$dispatch_body" "$keyword"
    done <"$quota_rows"
  fi
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
