# GLM worker Plugin·Superpowers Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `glm-agent`를 Claude Code marketplace/plugin으로 배포하고, 지속형 `explorer`·`general-purpose` GLM worker와 quota 소진 시 native Claude fallback 정책을 `my-superpowers`에 연결한다.

**Architecture:** 하나의 Bash CLI가 worker session·turn·result·provider 오류를 관리하고, 역할별 Claude Code custom agent 두 개가 `${CLAUDE_PLUGIN_ROOT}/glm-agent`를 호출하는 얇은 bridge가 된다. Superpowers SDD가 worktree·병렬도·native/GLM provider 선택을 소유하며, GLM worker는 저장된 role/model/cwd/session을 후속 turn에서 그대로 재사용한다.

**Tech Stack:** Bash 3.2+, jq, Claude Code 2.1.283+ plugin manifests, Markdown custom agents/system prompts, shellcheck

**Spec:** `superpowers/specs/2026-09-28-glm-worker-plugin-routing-design.md`

## Global Constraints

- Bash wrapper v1을 유지하고 MCP server, daemon, database, 다른 구현 언어를 추가하지 않는다.
- `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`을 유지한다.
- `haiku=glm-5.3-flash[1m]`, `sonnet=glm-5.3[1m]`, `opus=glm-5.3[1m]`을 유지한다.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `API_TIMEOUT_MS=3000000`을 유지한다.
- inherited `CLAUDECODE`를 unset하고 API key와 Claude session ID를 stdout에 노출하지 않는다.
- explorer와 general-purpose 모두 내부 GLM session을 `--dangerously-skip-permissions`로 실행한다.
- explorer의 비수정은 행동 계약이며 permission mode, Bash allowlist, 별도 sandbox로 강제하지 않는다.
- custom agent는 worktree를 생성·삭제·전환하지 않는다. Superpowers SDD가 준비한 `cwd`만 사용한다.
- 공통 system prompt와 role prompt는 별도 Markdown 파일에서 매 turn 직접 읽는다.
- `DONE`·`BLOCKED`는 turn 상태이며 worker close가 아니다. close는 명시적 요청에서만 수행한다.
- `glm-5.3-flashx`는 GLM Coding Plan 지원이 확인될 때까지 기본 mapping에 넣지 않는다.
- CLI, plugin manifest, marketplace entry의 최초 버전은 모두 `0.2.0`이다.

## Review Focus

- `role`, model, cwd, worker ID에 newline·path traversal 같은 metadata 입력이 들어오면 실행 전에 거부하고 기존 worker state를 손상하지 않아야 한다. Task 1의 invalid-role·stored-role 테스트가 이를 고정한다.
- HTTP 429 전체를 quota로 보지 말고 Z.ai business code `1113`, `1308`, `1310`, `1316`–`1321`만 native fallback 대상으로 분류해야 한다. Task 2의 code table 테스트가 이를 고정한다.
- `send`가 호출 위치의 cwd/model/role을 사용하거나 새 session을 만들면 안 된다. Task 1의 cross-directory resume 테스트가 네 값을 함께 검증한다.
- plugin checkout/cache 경로에 공백이 있어도 `${CLAUDE_PLUGIN_ROOT}` 실행 경로가 깨지면 안 된다. Task 3의 space-path validation 테스트가 이를 고정한다.
- API key·Claude session ID·raw stderr가 CLI·bridge 정상 stdout에 섞이면 안 된다. Task 2와 Task 3의 secret/control-plane 테스트가 이를 고정한다.

---

### Task 1: Role-aware persistent workers and direct role prompts

**Files:**
- Create: `prompts/explorer.md`
- Create: `prompts/general-purpose.md`
- Modify: `glm-agent:7-584`
- Modify: `tests/test_glm_agent.sh:10-397`

**Interfaces:**
- Consumes: existing `run_turn(worker_id, prompt)`, worker `meta`, `GLM_SYSTEM_PROMPT_FILE`.
- Produces: `start --role explorer|general-purpose`, metadata key `role`, control field `ROLE`, `GLM_ROLE_PROMPTS_DIR`, `role_prompt_file(role)`, and role-preserving `send`.

- [ ] **Step 1: Add failing role and prompt-source tests**

Add a role prompt directory to the test fixture:

```bash
TEST_ROLE_PROMPTS_DIR="$TEST_ROOT/prompts"
mkdir -p "$TEST_ROLE_PROMPTS_DIR"
export GLM_ROLE_PROMPTS_DIR="$TEST_ROLE_PROMPTS_DIR"

write_test_role_prompts() {
  local revision="$1"
  printf 'ROLE=explorer\nROLE_PROMPT_REVISION=%s\n' "$revision" \
    >"$TEST_ROLE_PROMPTS_DIR/explorer.md"
  printf 'ROLE=general-purpose\nROLE_PROMPT_REVISION=%s\n' "$revision" \
    >"$TEST_ROLE_PROMPTS_DIR/general-purpose.md"
}
```

Extend the fake Claude log to record which role prompt was appended:

```bash
case "$append_prompt" in
  *'ROLE=explorer'*) printf '%s\n' 'role_prompt=explorer' ;;
  *'ROLE=general-purpose'*) printf '%s\n' 'role_prompt=general-purpose' ;;
  *) printf '%s\n' 'role_prompt=missing' ;;
esac
case "$append_prompt" in
  *'ROLE_PROMPT_REVISION=two'*) printf '%s\n' 'role_prompt_revision=two' ;;
  *) printf '%s\n' 'role_prompt_revision=one' ;;
esac
```

Add assertions covering default role, explicit explorer, invalid role, and send persistence:

```bash
assert_contains 'start reports default role' "$start_output" 'ROLE=general-purpose'
assert_eq 'start stores default role' 'general-purpose' "$(meta_get_test "$meta" role)"
assert_contains 'default role prompt is loaded' "$start_log" 'role_prompt=general-purpose'

capture "$SCRIPT" start --role invalid --cwd "$PROJECT" 'must not start'
assert_eq 'invalid role is rejected' '2' "$RC"
assert_contains 'invalid role error is clear' "$STDERR" 'invalid role: invalid'

write_test_role_prompts two
capture "$SCRIPT" start --role explorer --model haiku --cwd "$OTHER_PROJECT" \
  'inspect the repository without changing it'
assert_eq 'explorer start succeeds' '0' "$RC"
explorer_id="$(printf '%s\n' "$OUTPUT" | sed -n 's/^WORKER_ID=//p')"
assert_contains 'explorer start reports role' "$OUTPUT" 'ROLE=explorer'
explorer_meta="$GLM_AGENT_HOME/workers/$explorer_id/meta"
assert_eq 'explorer role is stored' 'explorer' "$(meta_get_test "$explorer_meta" role)"

capture "$SCRIPT" send "$explorer_id" 'continue the same investigation'
assert_eq 'explorer send succeeds' '0' "$RC"
assert_contains 'explorer send reports stored role' "$OUTPUT" 'ROLE=explorer'
assert_eq 'explorer send preserves model' 'haiku' "$(meta_get_test "$explorer_meta" model)"
assert_eq 'explorer send preserves cwd' "$OTHER_PROJECT" "$(meta_get_test "$explorer_meta" cwd)"

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
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
bash tests/test_glm_agent.sh
```

Expected: FAIL because `start` does not recognize `--role`, `ROLE=` is absent, and role prompt files are not loaded.

- [ ] **Step 3: Add role validation, metadata, output, and prompt loading**

Add configuration and validation near the existing prompt variables:

```bash
ROLE_PROMPTS_DIR="${GLM_ROLE_PROMPTS_DIR:-$SCRIPT_DIR/prompts}"
DEFAULT_ROLE="${GLM_ROLE:-general-purpose}"

validate_role() {
  case "$1" in
    explorer|general-purpose) return 0 ;;
    *) die "invalid role: $1" ;;
  esac
}

role_prompt_file() {
  printf '%s/%s.md\n' "$ROLE_PROMPTS_DIR" "$1"
}
```

In `cmd_start`, parse `--role`, validate it, and write it to `meta`:

```bash
local role="$DEFAULT_ROLE"

--role)
  (($# >= 2)) || die "--role requires a value"
  role="$2"
  shift 2
  ;;

validate_role "$role"

role=$role
```

In `run_turn`, load and append both prompt files on every turn:

```bash
local role
local role_prompt_path
local role_prompt

role="$(meta_get "$dir" role)"
validate_role "$role"
role_prompt_path="$(role_prompt_file "$role")"
[[ -r "$role_prompt_path" && -s "$role_prompt_path" ]] ||
  die "role prompt file is missing, unreadable, or empty: $role_prompt_path"
system_prompt="$(<"$SYSTEM_PROMPT_FILE")"
role_prompt="$(<"$role_prompt_path")"
system_prompt+=$'\n\n<worker_role>\n'
system_prompt+="$role_prompt"
system_prompt+=$'\n</worker_role>'
```

Extend `print_turn_control`, `status`, and `list` with the stored role. Do not accept a role argument in `send`.

- [ ] **Step 4: Create the role prompt files**

Create `prompts/explorer.md`:

```markdown
You are a codebase exploration worker. Investigate the delegated questions by
using the available Claude Code tools, including Bash, Grep, Glob, and Read when
useful. Collect concrete evidence with file paths, symbols, commands, and
observed output. Focus on investigation and reporting; do not intentionally
modify the codebase. Before reporting, inspect git status and disclose any
unexpected change. Do not create or manage git worktrees.
```

Create `prompts/general-purpose.md`:

```markdown
You are a general-purpose implementation worker. Implement the delegated task
in the working directory, inspect existing conventions, run the relevant tests
and checks, and fix failures when reasonably possible. Do not create, switch,
or remove git worktrees; the parent orchestrator owns worktree lifecycle.
```

- [ ] **Step 5: Run tests and syntax checks and verify GREEN**

Run:

```bash
bash tests/test_glm_agent.sh
bash -n glm-agent tests/test_glm_agent.sh
```

Expected: all TAP assertions pass; syntax checks exit 0.

- [ ] **Step 6: Commit Task 1**

```bash
git add glm-agent prompts/explorer.md prompts/general-purpose.md tests/test_glm_agent.sh
git diff --cached --check
git commit -m "feat: add persistent GLM worker roles"
```

### Task 2: Z.ai error classification and quota fallback signals

**Files:**
- Modify: `glm-agent:248-434`
- Modify: `tests/test_glm_agent.sh:85-370`

**Interfaces:**
- Consumes: `response.json`, `stderr.log`, existing `INVALID` paths.
- Produces: `extract_zai_code(response_file, stderr_file)`, `classify_error_kind(provider_code, default_kind)`, metadata keys `error_kind` and `provider_code`, and fields `ERROR_KIND`, `PROVIDER_CODE`, `FALLBACK_RECOMMENDED`.

- [ ] **Step 1: Add fake provider failures and failing classification tests**

Add this before the generic `CLAUDE_FAIL` branch in fake Claude:

```bash
if [[ "$prompt" =~ ZAI_ERROR_([0-9]+) ]]; then
  zai_code="${BASH_REMATCH[1]}"
  printf '{"error":{"code":"%s","message":"simulated provider error"}}\n' \
    "$zai_code" >&2
  exit 1
fi
```

Add table-driven assertions:

```bash
for code in 1113 1308 1310 1316 1317 1318 1319 1320 1321; do
  capture "$SCRIPT" send "$worker_id" "ZAI_ERROR_$code"
  assert_eq "quota code $code fails the turn" '1' "$RC"
  assert_contains "quota code $code is classified" "$OUTPUT" \
    'ERROR_KIND=quota-exhausted'
  assert_contains "quota code $code is retained" "$OUTPUT" \
    "PROVIDER_CODE=$code"
  assert_contains "quota code $code recommends fallback" "$OUTPUT" \
    'FALLBACK_RECOMMENDED=true'
done

for code_and_kind in \
  '1302 provider-transient' \
  '1305 provider-transient' \
  '1000 authentication' \
  '1001 authentication' \
  '1003 authentication' \
  '1211 model-unavailable' \
  '1311 model-unavailable'; do
  set -- $code_and_kind
  capture "$SCRIPT" send "$worker_id" "ZAI_ERROR_$1"
  assert_contains "provider code $1 kind" "$OUTPUT" "ERROR_KIND=$2"
  assert_contains "provider code $1 does not fallback" "$OUTPUT" \
    'FALLBACK_RECOMMENDED=false'
done

capture "$SCRIPT" send "$worker_id" 'MISSING_RESULT'
assert_contains 'protocol errors are classified' "$OUTPUT" \
  'ERROR_KIND=worker-protocol'
assert_contains 'protocol errors do not fallback' "$OUTPUT" \
  'FALLBACK_RECOMMENDED=false'

capture "$SCRIPT" start --role general-purpose --cwd "$PROJECT" 'successful control fields'
assert_contains 'success has empty error kind' "$OUTPUT" $'ERROR_KIND=\n'
assert_contains 'success has empty provider code' "$OUTPUT" $'PROVIDER_CODE=\n'
assert_contains 'success does not recommend fallback' "$OUTPUT" \
  'FALLBACK_RECOMMENDED=false'
```

Replace tests that assume the last turn is `0007` with the turn read from `meta`, so the table does not make the suite order-dependent:

```bash
latest_turn="$(meta_get_test "$meta" turn)"
printf -v latest_turn_label '%04d' "$latest_turn"
assert_file 'close preserves latest prompt' \
  "$GLM_AGENT_HOME/workers/$worker_id/turns/$latest_turn_label/prompt.md"
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
bash tests/test_glm_agent.sh
```

Expected: FAIL because error classification fields do not exist.

- [ ] **Step 3: Implement exact provider-code extraction and classification**

Add these functions:

```bash
extract_zai_code() {
  local response_file="$1"
  local stderr_file="$2"
  local code=""

  code="$(
    { cat "$response_file"; cat "$stderr_file"; } 2>/dev/null |
      grep -Eo '"code"[[:space:]]*:[[:space:]]*"?[0-9]+' |
      sed -E 's/.*"?([0-9]+)$/\1/' |
      head -n 1
  )" || true
  printf '%s\n' "$code"
}

classify_error_kind() {
  local provider_code="$1"
  local default_kind="$2"

  case "$provider_code" in
    1113|1308|1310|1316|1317|1318|1319|1320|1321)
      printf '%s\n' 'quota-exhausted'
      ;;
    1302|1305) printf '%s\n' 'provider-transient' ;;
    1000|1001|1003) printf '%s\n' 'authentication' ;;
    1211|1311) printf '%s\n' 'model-unavailable' ;;
    '') printf '%s\n' "$default_kind" ;;
    *) printf '%s\n' 'provider-error' ;;
  esac
}
```

Expand `print_turn_control` to accept `error_kind` and `provider_code` and always print a stable field set. Successful turns pass empty strings and print `FALLBACK_RECOMMENDED=false`. Expand `invalidate_turn` to save the fields in `meta` and call the same printer:

```bash
printf 'ERROR_KIND=%s\n' "$error_kind"
printf 'PROVIDER_CODE=%s\n' "$provider_code"
if [[ "$error_kind" == 'quota-exhausted' ]]; then
  printf '%s\n' 'FALLBACK_RECOMMENDED=true'
else
  printf '%s\n' 'FALLBACK_RECOMMENDED=false'
fi
```

Use `invocation` as the default kind for nonzero Claude exit, and `worker-protocol` for invalid response/session/result contract failures. On a valid turn, clear stale `error_kind` and `provider_code` metadata.

Initialize the metadata keys when a worker is created:

```text
error_kind=
provider_code=
```

Include them in `status` without exposing raw provider messages.

- [ ] **Step 4: Verify secret and control-plane behavior**

Add assertions that neither the stored test key nor `session-1` appears in quota-failure stdout/stderr. Run:

```bash
bash tests/test_glm_agent.sh
bash -n glm-agent tests/test_glm_agent.sh
```

Expected: all tests pass and syntax checks exit 0.

- [ ] **Step 5: Commit Task 2**

```bash
git add glm-agent tests/test_glm_agent.sh
git diff --cached --check
git commit -m "feat: classify Z.ai provider failures"
```

### Task 3: Claude Code marketplace and role agents

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `agents/explorer.md`
- Create: `agents/general-purpose.md`
- Create: `tests/test_plugin.sh`

**Interfaces:**
- Consumes: Task 1 `start --role`, Task 2 control fields, `${CLAUDE_PLUGIN_ROOT}`.
- Produces: installable plugin `glm-agent@glm-agent`, custom agents `glm-agent:explorer` and `glm-agent:general-purpose`.

- [ ] **Step 1: Write the failing static plugin test**

Create `tests/test_plugin.sh` with the same TAP-style `pass`, `fail`, `assert_eq`, and `assert_contains` helpers as the CLI suite. Include these checks:

```bash
plugin_json="$REPO_DIR/.claude-plugin/plugin.json"
marketplace_json="$REPO_DIR/.claude-plugin/marketplace.json"
explorer_agent="$REPO_DIR/agents/explorer.md"
general_agent="$REPO_DIR/agents/general-purpose.md"

assert_file 'plugin manifest exists' "$plugin_json"
assert_file 'marketplace manifest exists' "$marketplace_json"
assert_file 'explorer agent exists' "$explorer_agent"
assert_file 'general-purpose agent exists' "$general_agent"
assert_eq 'plugin name' 'glm-agent' "$(jq -r '.name' "$plugin_json")"
assert_eq 'marketplace source' './' \
  "$(jq -r '.plugins[] | select(.name == "glm-agent") | .source' "$marketplace_json")"
assert_contains 'explorer uses plugin-root CLI' "$(cat "$explorer_agent")" \
  '${CLAUDE_PLUGIN_ROOT}/glm-agent'
assert_contains 'general agent never auto-closes' "$(cat "$general_agent")" \
  'Never close a worker merely because a turn returned DONE or BLOCKED.'
```

Copy the repository to a temporary path containing a space and run `claude plugin validate --strict` there when `claude` is available.

- [ ] **Step 2: Run the plugin test and verify RED**

Run:

```bash
bash tests/test_plugin.sh
```

Expected: FAIL because manifests and agents do not exist.

- [ ] **Step 3: Create the exact plugin and marketplace manifests**

Create `.claude-plugin/plugin.json`:

```json
{
  "name": "glm-agent",
  "version": "0.2.0",
  "description": "Persistent Z.ai GLM workers for Claude Code orchestration",
  "author": { "name": "Heejoon Kang" },
  "homepage": "https://github.com/powdream-org/glm-agent",
  "repository": "https://github.com/powdream-org/glm-agent",
  "license": "MIT",
  "keywords": ["glm", "z.ai", "subagents", "orchestration"]
}
```

Create `.claude-plugin/marketplace.json`:

```json
{
  "name": "glm-agent",
  "description": "Claude Code plugins from powdream-org/glm-agent",
  "owner": { "name": "powdream-org" },
  "plugins": [
    {
      "name": "glm-agent",
      "description": "Persistent Z.ai GLM workers for Claude Code orchestration",
      "version": "0.2.0",
      "source": "./",
      "author": { "name": "Heejoon Kang" }
    }
  ]
}
```

- [ ] **Step 4: Create the explorer bridge agent**

Create `agents/explorer.md` with this complete behavioral contract:

```markdown
---
name: explorer
description: Use when the orchestrator explicitly chooses Z.ai GLM for repository exploration, symbol search, dependency tracing, or evidence collection that does not require a Claude connector/MCP.
tools: Bash, Read
model: haiku
---

You are a thin control-plane bridge to a persistent GLM explorer. The parent
owns task decomposition, worktrees, provider routing, review, and fallback.
Never create, switch, or delete a worktree.

Accept ACTION, CWD, TASK, optional GLM_MODEL, and optional WORKER_ID from the
delegation prompt. For ACTION=start, require CWD and TASK, default GLM_MODEL to
haiku, and construct one Bash call whose arguments are `bash`,
`${CLAUDE_PLUGIN_ROOT}/glm-agent`, `start`, `--role`, `explorer`, `--model`, the
GLM_MODEL value, `--cwd`, the CWD value, and TASK as one final argument.

For ACTION=send, require WORKER_ID and TASK and invoke `send`; do not accept a
new cwd, role, or model. For status, result, and close, invoke the matching CLI
command. Quote every shell argument and never use eval.

The GLM session may use Bash, Grep, Glob, Read, and other Claude Code tools for
investigation. Its non-modification rule is behavioral, not a permission
sandbox. After a completed explorer turn, report the CLI control fields and
the result path; the parent verifies findings and checks for unexpected diffs.

Prefix the CLI stdout with `PROVIDER=glm` and return it without raw response,
stderr, API keys, or Claude session IDs. Never close a worker merely because a
turn returned DONE or BLOCKED. On quota-exhausted, preserve the worker and
return the fallback fields so the parent can dispatch native Claude.
```

- [ ] **Step 5: Create the general-purpose bridge agent**

Create `agents/general-purpose.md` with this complete behavioral contract:

```markdown
---
name: general-purpose
description: Use when the orchestrator explicitly chooses Z.ai GLM for implementation, refactoring, testing, or debugging in an already selected working directory.
tools: Bash, Read
model: haiku
---

You are a thin control-plane bridge to a persistent general-purpose GLM worker.
The parent owns task decomposition, worktrees, provider routing, review, and
fallback. Never create, switch, or delete a worktree.

Accept ACTION, CWD, TASK, optional GLM_MODEL, and optional WORKER_ID from the
delegation prompt. For ACTION=start, require CWD and TASK, default GLM_MODEL to
sonnet, and construct one Bash call whose arguments are `bash`,
`${CLAUDE_PLUGIN_ROOT}/glm-agent`, `start`, `--role`, `general-purpose`,
`--model`, the GLM_MODEL value, `--cwd`, the CWD value, and TASK as one final
argument.

For ACTION=send, require WORKER_ID and TASK and invoke `send`; do not accept a
new cwd, role, or model. For status, result, and close, invoke the matching CLI
command. Quote every shell argument and never use eval.

Prefix the CLI stdout with `PROVIDER=glm` and return it without raw response,
stderr, API keys, or Claude session IDs. Never close a worker merely because a
turn returned DONE or BLOCKED. On quota-exhausted, preserve the worker and
return the fallback fields so the parent can dispatch native Claude.
```

- [ ] **Step 6: Validate the plugin and verify GREEN**

Run:

```bash
bash tests/test_plugin.sh
claude plugin validate --strict .
```

Expected: TAP suite passes; Claude validation exits 0 with no warnings treated as errors.

- [ ] **Step 7: Commit Task 3**

```bash
git add .claude-plugin agents tests/test_plugin.sh
git diff --cached --check
git commit -m "feat: add the Claude Code GLM plugin"
```

### Task 4: Synchronized version bump workflow and parity gate

**Files:**
- Create: `scripts/bump-version.sh`
- Modify: `tests/test_plugin.sh`
- Modify: `AGENTS.md:17-25,74-94`

**Interfaces:**
- Consumes: CLI `VERSION="x.y.z"`, both JSON manifest versions.
- Produces: `scripts/bump-version.sh <semver>` and a parity test that blocks mismatched releases.

- [ ] **Step 1: Add failing parity and bump-script tests**

Add to `tests/test_plugin.sh`:

```bash
cli_version="$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$REPO_DIR/glm-agent")"
plugin_version="$(jq -r '.version' "$plugin_json")"
marketplace_version="$(jq -r '.plugins[] | select(.name == "glm-agent") | .version' "$marketplace_json")"
assert_eq 'CLI and plugin versions match' "$cli_version" "$plugin_version"
assert_eq 'CLI and marketplace versions match' "$cli_version" "$marketplace_version"

fixture="$TEST_ROOT/version fixture"
cp -R "$REPO_DIR" "$fixture"
"$fixture/scripts/bump-version.sh" 0.2.1
assert_eq 'bump updates CLI' 'glm-agent 0.2.1' "$($fixture/glm-agent --version)"
assert_eq 'bump updates plugin manifest' '0.2.1' \
  "$(jq -r '.version' "$fixture/.claude-plugin/plugin.json")"
assert_eq 'bump updates marketplace' '0.2.1' \
  "$(jq -r '.plugins[0].version' "$fixture/.claude-plugin/marketplace.json")"
```

Also assert that `1.2`, `v1.2.3`, and an empty argument fail without changing files.

- [ ] **Step 2: Run the plugin test and verify RED**

Run:

```bash
bash tests/test_plugin.sh
```

Expected: FAIL because `scripts/bump-version.sh` does not exist.

- [ ] **Step 3: Implement the version bump script**

Create a Bash 3.2-compatible script that:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
version="${1:-}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'usage: %s <major.minor.patch>\n' "${0##*/}" >&2
  exit 2
}
```

Use `mktemp` files under the repository, `sed` for the CLI assignment, and `jq --arg version` for each JSON manifest. Validate all three temporary outputs before moving them into place, then set `glm-agent` and the bump script executable. Do not commit, tag, or push from this script.

- [ ] **Step 4: Update repository instructions**

Add plugin/agent/prompt/script files to the `AGENTS.md` layout. Add `bash tests/test_plugin.sh` and `claude plugin validate --strict .` to required checks. State that releases must use the bump script and pass parity tests.

- [ ] **Step 5: Verify version workflow and static checks**

Run:

```bash
bash tests/test_plugin.sh
bash -n scripts/bump-version.sh tests/test_plugin.sh
claude plugin validate --strict .
```

Expected: all checks pass; the real checkout remains at `0.2.0` because only the fixture is bumped.

- [ ] **Step 6: Commit Task 4**

```bash
git add scripts/bump-version.sh tests/test_plugin.sh AGENTS.md
git diff --cached --check
git commit -m "build: keep plugin versions synchronized"
```

### Task 5: Public documentation and `my-superpowers` routing policy

**Files:**
- Modify: `README.md:20-185`
- Modify: `glm-agent:23-119`
- Modify outside repository: `/Users/h_kang/.claude/skills/my-superpowers/SKILL.md:§6`
- Modify: `superpowers/plans/2026-09-28-glm-worker-plugin-routing-progress.md`

**Interfaces:**
- Consumes: plugin ID `glm-agent@glm-agent`, role agents, fallback fields.
- Produces: install/use documentation, synchronized CLI help, and user-scope provider routing before every Superpowers Agent dispatch.

- [ ] **Step 1: Add failing help/documentation assertions**

Add to `tests/test_glm_agent.sh`:

```bash
assert_contains 'help documents role option' "$help_output" \
  'start [--role <role>] [--model <alias>]'
assert_contains 'help documents explorer role' "$help_output" \
  'explorer'
assert_contains 'help documents fallback signal' "$help_output" \
  'FALLBACK_RECOMMENDED'
```

Add to `tests/test_plugin.sh`:

```bash
readme="$(cat "$REPO_DIR/README.md")"
assert_contains 'README documents marketplace add' "$readme" \
  'claude plugin marketplace add powdream-org/glm-agent'
assert_contains 'README documents plugin install' "$readme" \
  'claude plugin install glm-agent@glm-agent'
assert_contains 'README documents both agents' "$readme" \
  'glm-agent:explorer'
assert_contains 'README documents native connector routing' "$readme" \
  'connector/MCP'
```

- [ ] **Step 2: Run both suites and verify RED**

Run:

```bash
bash tests/test_glm_agent.sh
bash tests/test_plugin.sh
```

Expected: documentation/help assertions fail.

- [ ] **Step 3: Update CLI help and README**

Document these public workflows exactly:

```bash
claude plugin marketplace add powdream-org/glm-agent
claude plugin install glm-agent@glm-agent --scope user
```

Explain:

- `glm-agent:explorer` defaults to GLM Haiku/Flash for codebase research.
- `glm-agent:general-purpose` defaults to GLM Sonnet for implementation.
- either agent can start Opus/Sonnet/Haiku logical workers.
- `send` continues the same role/model/cwd/session and `close` is explicit.
- both roles use `--dangerously-skip-permissions`; explorer non-modification is behavioral.
- connector/MCP work, design/safety rulings, and provider work prefer native Claude.
- only `ERROR_KIND=quota-exhausted` with `FALLBACK_RECOMMENDED=true` triggers automatic native fallback.
- standalone copies now require `glm-agent`, `system-prompt.md`, and the `prompts/` directory together.

Update help output fields to include `ROLE`, `ERROR_KIND`, `PROVIDER_CODE`, and `FALLBACK_RECOMMENDED`.

- [ ] **Step 4: Update the personal `my-superpowers` skill in place**

In `/Users/h_kang/.claude/skills/my-superpowers/SKILL.md` §6, preserve the existing thin-main, ledger, model-tier, file-return, and verification rules. Add this provider-routing subsection before “띄우는 방법”:

```markdown
### native Claude와 GLM provider 선택

Agent 좌석을 만들기로 결정한 뒤, 매 dispatch마다 모델 등급과 별도로 provider를
선택한다.

- 저장소 내부의 파일·심볼·참조·테스트 위치 조사와 근거 수집은
  `glm-agent:explorer`를 우선 고려한다.
- 범위와 검증 방법이 명확한 구현·수정·테스트·디버깅은
  `glm-agent:general-purpose`를 고려한다.
- connector/MCP가 필요하거나 사용자 의도·설계·안전·권한 판단, GLM 자체의
  수정, 최종 독립 판정이 필요한 작업은 native Claude를 우선한다.
- GLM bridge Agent 자체는 `model: haiku`로 호출하고, 실제 GLM 등급은 위임
  prompt의 `GLM_MODEL=opus|sonnet|haiku`로 명시한다.
- 후속 지시는 가능하면 같은 bridge agent를 resume하고, 그렇지 못하면 반환된
  `WORKER_ID`로 같은 GLM worker에 `ACTION=send`한다. DONE/BLOCKED만으로 worker를
  닫지 않는다.
- `ERROR_KIND=quota-exhausted`와 `FALLBACK_RECOMMENDED=true`를 받으면 현재 작업의
  Z.ai quota latch를 세우고 같은 논리 등급의 native Claude agent로 재dispatch한다.
  provider가 reset 시각을 반환하면 그 시각까지, 없으면 현재 orchestration
  session 동안 새 GLM worker를 시작하지 않는다.
  그 밖의 인증·모델·일시 장애·worker protocol 오류는 자동 fallback으로 숨기지
  않는다.
```

Do not replace upstream `using-superpowers`; this is a user-scope overlay that applies whenever later Superpowers skills dispatch Agent seats.

- [ ] **Step 5: Verify documentation and personal skill changes**

Run:

```bash
bash tests/test_glm_agent.sh
bash tests/test_plugin.sh
rg -n 'glm-agent:(explorer|general-purpose)|FALLBACK_RECOMMENDED|connector/MCP' \
  README.md glm-agent /Users/h_kang/.claude/skills/my-superpowers/SKILL.md
```

Expected: both suites pass and every routing term appears in the intended files.

- [ ] **Step 6: Record the external skill update and commit repository files**

Append the exact changed section and verification result to the progress ledger because the user-scope skill is not version-controlled. Then run:

```bash
git add README.md glm-agent tests/test_glm_agent.sh tests/test_plugin.sh \
  superpowers/plans/2026-09-28-glm-worker-plugin-routing-progress.md
git diff --cached --check
git commit -m "docs: document GLM worker routing"
```

### Task 6: End-to-end validation and install smoke test

**Files:**
- Modify only if verification reveals a defect: files owned by Tasks 1–5
- Modify: `superpowers/plans/2026-09-28-glm-worker-plugin-routing-progress.md`

**Interfaces:**
- Consumes: complete CLI, plugin, marketplace, personal routing policy.
- Produces: reproducible verification evidence, isolated marketplace install proof, and optional live Z.ai persistence proof.

- [ ] **Step 1: Run the complete local gate**

Run:

```bash
bash tests/test_glm_agent.sh
bash tests/test_plugin.sh
bash -n glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh
shellcheck glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh
claude plugin validate --strict .
git diff --check
```

Expected: zero failures and zero strict validation warnings. If shellcheck is unavailable, record that exact fact rather than claiming it passed.

- [ ] **Step 2: Test marketplace installation in an isolated Claude config**

Run without changing the user's normal plugin configuration:

```bash
smoke_root="$(mktemp -d /tmp/glm-agent-plugin-smoke.XXXXXX)"
repo_root="$(git rev-parse --show-toplevel)"
CLAUDE_CONFIG_DIR="$smoke_root/claude" claude plugin marketplace add \
  "$repo_root"
CLAUDE_CONFIG_DIR="$smoke_root/claude" claude plugin install \
  glm-agent@glm-agent --scope user
CLAUDE_CONFIG_DIR="$smoke_root/claude" claude plugin details \
  glm-agent@glm-agent
CLAUDE_CONFIG_DIR="$smoke_root/claude" claude plugin list
```

Expected: install succeeds and details inventory lists both `explorer` and `general-purpose` agents at version `0.2.0`.

- [ ] **Step 3: Run an optional narrow live Z.ai persistence smoke**

Only when `~/.glm/.env.auth` already exists and no key content is printed, create a temporary git repository and run:

```bash
smoke_repo="$(mktemp -d /tmp/glm-agent-live.XXXXXX)"
git -C "$smoke_repo" init
start_output="$(./glm-agent start --role explorer --model haiku --cwd "$smoke_repo" \
  'Inspect this empty repository, write the required result, and do not modify tracked files.')"
worker_id="$(printf '%s\n' "$start_output" | sed -n 's/^WORKER_ID=//p')"
./glm-agent send "$worker_id" \
  'State whether this is the same session and write the required result.'
./glm-agent status "$worker_id"
./glm-agent close "$worker_id"
```

Expected: both turns report `ROLE=explorer`, the second turn increments `TURN`, status omits the Claude session ID, and close preserves history. If credentials or quota are unavailable, record the classified output and do not expose the key.

- [ ] **Step 4: Inspect final state and documentation consistency**

Run:

```bash
git status --short --branch
git diff origin/main...HEAD --stat
git diff origin/main...HEAD --name-only
./glm-agent --help
./glm-agent --version
jq -r '.version' .claude-plugin/plugin.json
jq -r '.plugins[0].version' .claude-plugin/marketplace.json
```

Expected: only planned files changed, all three versions are `0.2.0`, and help matches README examples.

- [ ] **Step 5: Record final evidence and commit only if the ledger changed**

Append command, result, timestamp, plugin inventory, and live-smoke outcome to the progress ledger. Then:

```bash
git add superpowers/plans/2026-09-28-glm-worker-plugin-routing-progress.md
git diff --cached --check
git commit -m "docs: record GLM plugin verification"
```
