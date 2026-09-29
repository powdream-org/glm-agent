# glm-agent TUI 및 비동기 감독 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 영속 GLM worker에 관리형 Claude Code TUI, 즉시 반환되는 비동기 turn, bounded wait, process-group cancel, bridge 복구 프로토콜을 추가하고 0.4.0으로 배포한다.

**Architecture:** 단일 Bash CLI의 기존 `run_turn()`을 준비·실행·종료 단계로 분리하고, worker별 원자적 lock 디렉터리를 단일 소유권 경계로 사용한다. 동기 경로는 같은 executor를 foreground에서 실행하고, 비동기 경로는 stdio가 분리된 one-turn runner를 실행한다. TUI는 같은 worker metadata와 session ID를 사용하지만 mode별 artifact를 남긴다.

**Tech Stack:** macOS Bash 3.2+, Claude Code CLI, `jq`, POSIX filesystem/process primitives, Claude Code plugin Markdown agents.

**Spec:** `superpowers/specs/2026-09-29-glm-agent-tui-async-design.md`

## 전역 제약

- 목표 버전은 CLI·plugin manifest·marketplace가 모두 `0.4.0`이다.
- 기본 model alias는 `sonnet`; `haiku=glm-5.3-flash[1m]`, `sonnet=glm-5.3[1m]`, `opus=glm-5.3[1m]`을 보존한다.
- `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `API_TIMEOUT_MS=3000000`, inherited `CLAUDECODE` 제거를 보존한다.
- API key는 `~/.glm/.env.auth`에만 저장하고 stdout/stderr와 테스트 로그에 노출하지 않는다.
- Bash wrapper v1 범위를 유지한다. MCP server, daemon, database, private Claude transcript parsing은 추가하지 않는다.
- worker의 원래 cwd/model/role/session을 `send`와 `tui <worker-id>`에서 변경하지 않는다.
- close는 history를 보존하며, active worker를 닫지 않는다.
- async runner argv에는 task 본문이나 API key를 넣지 않는다.
- background startup은 semantic completion이 아니며, 유효한 `result.md`의 마지막 줄만 `DONE|BLOCKED`를 결정한다.

## 파일 구조

- `glm-agent`: 상태 machine, lock, synchronous/asynchronous executor, wait/cancel, TUI, CLI help를 소유한다.
- `tests/test_glm_agent.sh`: fake Claude를 통한 CLI·artifact·process lifecycle 회귀 테스트를 소유한다.
- `agents/explorer.md`, `agents/general-purpose.md`: bridge ACTION protocol과 async routing 규칙을 소유한다.
- `tests/test_plugin.sh`: agent prompt·version parity·plugin validation 계약을 소유한다.
- `README.md`: 사용자 명령, 복구, 취소, TUI workflow를 소유한다.
- `/Users/h_kang/.claude/skills/my-superpowers/SKILL.md`: native/GLM provider 선택 후 async worker를 시작·회수·취소하는 orchestration 정책을 소유한다. 실행 때 `superpowers:writing-skills`를 사용해 수정·검증한다.

## 리뷰 초점

- async receipt 직후 bridge가 종료되어도 runner가 완료되고 lock이 해제되어야 한다. Task 2의 parent-exit 테스트가 고정한다.
- `cancel`이 provider 시작 전·실행 중·자연 종료 직후 들어와도 무관한 PID를 죽이지 않아야 한다. Task 3의 race/idempotency 테스트가 고정한다.
- exit 0이면서 `is_error=true`인 quota 응답도 fallback 가능한 `INVALID`여야 한다. Task 1의 JSON error 테스트가 고정한다.
- 다른 cwd에서 TUI attach해도 저장된 cwd/session/model/role만 사용하고 호출자 cwd는 유지되어야 한다. Task 4의 attach 테스트가 고정한다.
- stale lock, missing session/cwd, active close가 history 또는 이전 valid result를 손상시키지 않아야 한다. Task 2와 Task 4의 recovery 테스트가 고정한다.

---

### Task 1: turn state machine과 provider normalization 분리

**Files:**
- Modify: `glm-agent:271-491`
- Modify: `tests/test_glm_agent.sh`

**Interfaces:**
- Consumes: 기존 worker `meta`, `prompt.md`, role/system prompt, Z.ai environment.
- Produces: `acquire_worker_lock DIR MODE TURN`, `prepare_turn WORKER_ID PROMPT MODE`, `execute_headless_turn WORKER_ID TURN`, `finalize_interrupted_turn DIR TURN`, `release_worker_lock DIR`; 동기 `run_turn WORKER_ID PROMPT`는 이들을 조합한다.

- [ ] **Step 1: exit-zero provider error와 동시 send를 고정하는 실패 테스트를 작성한다**

  fake Claude에 아래 분기를 추가하고, `is_error=true` quota JSON이 `ERROR_KIND=quota-exhausted`, `PROVIDER_CODE=1113`, `FALLBACK_RECOMMENDED=true`로 끝나는지 검사한다.

  ```bash
  if [[ "$prompt" == *EXIT_ZERO_ZAI_ERROR* ]]; then
    printf '%s\n' '{"type":"result","is_error":true,"session_id":"session-1","error":{"code":1113}}'
    exit 0
  fi
  ```

  같은 worker에 두 `send`를 겹쳐 실행했을 때 하나만 turn을 소유하고 다른 하나는 exit 2와 `worker is active`를 반환하는 테스트도 추가한다.

- [ ] **Step 2: 새 테스트가 현재 구현에서 실패하는지 확인한다**

  Run: `bash tests/test_glm_agent.sh`

  Expected: exit-zero error가 `worker-protocol`로 분류되거나 두 turn이 함께 할당되어 FAIL.

- [ ] **Step 3: lock·준비·실행·종료 함수를 최소 구현한다**

  lock은 `DIR/active`를 `mkdir`로 획득하고 아래 single-line 파일을 mode `0600`으로 기록한다.

  ```text
  mode=headless
  turn=3
  runner_pid=
  provider_pgid=
  started_at=<epoch>
  ```

  `prepare_turn`은 lock 획득 후에만 turn 번호를 올리고 `mode`, `prompt.md`, 빈 `response.json`, `stderr.log` 경로를 준비한다. `execute_headless_turn`은 exit code보다 먼저 parse 가능한 JSON의 `is_error`, `error.code`, `result`를 검사하고 모든 종료 경로에서 metadata를 확정한 뒤 lock을 해제한다. 기존 synchronous stdout와 exit status는 그대로 유지한다.

- [ ] **Step 4: Task 1 테스트와 기존 sync 회귀를 실행한다**

  Run: `bash tests/test_glm_agent.sh`

  Expected: 전체 PASS; 기존 DONE/BLOCKED/INVALID, session resume, role/cwd/model 검사가 유지된다.

- [ ] **Step 5: Task 1을 커밋한다**

  ```bash
  git add glm-agent tests/test_glm_agent.sh
  git commit -m "refactor: split worker turn lifecycle"
  ```

### Task 2: detached async start/send, wait, status recovery

**Files:**
- Modify: `glm-agent`
- Modify: `tests/test_glm_agent.sh`

**Interfaces:**
- Consumes: Task 1의 `prepare_turn`, `execute_headless_turn`, lock metadata.
- Produces: internal `_execute-turn <worker-id> <turn>`, `launch_async_turn`, `cmd_wait`; `start --async`, `send --async`, stale-lock recovery, active status fields.

- [ ] **Step 1: async receipt·detachment·wait 실패 테스트를 작성한다**

  fake Claude에 `SLOW_DONE`일 때 marker를 만든 뒤 종료하는 controllable delay를 추가한다. `start --async`가 marker 전에 다음 필드를 즉시 반환하는지 검사한다.

  ```text
  WORKER_ID=<id>
  TURN=1
  STATUS=RUNNING
  RESULT=<turn result path>
  ```

  launching shell을 종료한 뒤에도 marker와 `STATUS=DONE`이 생기는지, `wait --timeout 0`은 `WAIT_RESULT=TIMEOUT`, terminal wait는 `WAIT_RESULT=TERMINAL`을 반환하는지 검사한다. inherited stdout/stderr를 열어 둔 단순 `&` 구현이면 테스트가 끝나지 않도록 command substitution의 반환 시간도 측정한다.

- [ ] **Step 2: 현재 CLI에서 async/wait가 없는 실패를 확인한다**

  Run: `bash tests/test_glm_agent.sh`

  Expected: `--async` 또는 `wait` unknown command로 FAIL.

- [ ] **Step 3: one-turn runner와 bounded wait를 구현한다**

  `launch_async_turn`은 task가 저장된 뒤 다음과 동등하게 실행하고 `$!`를 lock의 `runner_pid`에 기록한 다음 receipt를 반환한다.

  ```bash
  nohup "$SCRIPT_PATH" _execute-turn "$worker_id" "$turn" \
    </dev/null >"$turn_dir/runner.log" 2>&1 &
  ```

  internal command는 public help에서 숨기고 정확한 worker/turn/active-lock 일치를 검증한다. `wait`는 `0..300` 정수 timeout만 받고 짧은 polling으로 filesystem terminal state를 관찰한다. `status`와 `wait`는 죽은 runner의 lock을 `INVALID/interrupted`로 한 번만 복구하며 `ACTIVE_MODE`, `ACTIVE_TURN`을 출력한다. active worker의 `close`, `send`, `tui`는 exit 2로 거부한다.

- [ ] **Step 4: async·sync 전체 회귀를 실행한다**

  Run: `bash tests/test_glm_agent.sh`

  Expected: async parent-exit, timeout, terminal wait, stale recovery, active rejection을 포함해 전체 PASS.

- [ ] **Step 5: Task 2를 커밋한다**

  ```bash
  git add glm-agent tests/test_glm_agent.sh
  git commit -m "feat: add supervised async worker turns"
  ```

### Task 3: process-group cancel과 race-safe interruption

**Files:**
- Modify: `glm-agent`
- Modify: `tests/test_glm_agent.sh`

**Interfaces:**
- Consumes: Task 2의 runner PID, `active/provider_pgid`, filesystem wait.
- Produces: `cmd_cancel WORKER_ID`, `cancel.requested`, provider process-group TERM/KILL escalation, idempotent interrupted finalization.

- [ ] **Step 1: provider child까지 종료하는 실패 테스트를 작성한다**

  fake Claude의 `HANG_WITH_CHILD` 분기는 child marker/process를 만들고 기다린다. async receipt 후 `cancel`을 호출해 leader와 같은 PGID의 child가 모두 사라지고 다음이 유지되는지 검사한다.

  ```text
  STATUS=INVALID
  ERROR_KIND=interrupted
  ERROR=cancelled
  ```

  provider PGID 기록 전 cancel, 두 번 cancel, 자연 종료 직후 cancel, 위조되거나 stale인 PID/PGID가 현재 테스트 shell에 signal을 보내지 않는 경우를 각각 추가한다.

- [ ] **Step 2: 현재 cancel이 process group을 종료하지 못하는 실패를 확인한다**

  Run: `bash tests/test_glm_agent.sh`

  Expected: `cancel` unknown command 또는 child 생존으로 FAIL.

- [ ] **Step 3: runner process group과 cancel handshake를 구현한다**

  detached runner는 `set -m` 후 Claude를 background job으로 시작하고 `ps -o pgid=`로 actual PGID를 읽어 lock에 기록한 뒤 `wait`한다. `cancel`은 active identity 검증 → `cancel.requested` 생성 → negative PGID에 `TERM` → bounded grace → 재검증 후 `KILL` 순서로 동작한다. runner는 provider 시작 전과 PGID 기록 직후 marker를 확인하고, 정상 provider 종료와 cancel race에서는 이미 확정된 terminal state를 덮어쓰지 않는다.

- [ ] **Step 4: cancel 및 전체 lifecycle 테스트를 실행한다**

  Run: `bash tests/test_glm_agent.sh`

  Expected: provider group member 수가 0이고 worker는 idle `INVALID/interrupted`; 전체 PASS.

- [ ] **Step 5: Task 3을 커밋한다**

  ```bash
  git add glm-agent tests/test_glm_agent.sh
  git commit -m "feat: add process-group worker cancellation"
  ```

### Task 4: 관리형 TUI 생성과 기존 worker attach

**Files:**
- Modify: `glm-agent`
- Modify: `tests/test_glm_agent.sh`

**Interfaces:**
- Consumes: shared worker creation, lock, prompt composition, Z.ai environment.
- Produces: `cmd_tui`, UUID-format `new_claude_session_id`, mode `tui` artifact와 `exit.meta`.

- [ ] **Step 1: TUI 생성·attach 실패 테스트를 작성한다**

  fake Claude가 `-p` 부재, `--session-id`, `--resume`, cwd/model, permission flag를 기록하고 `GLM_RESULT_FILE`을 작성하도록 확장한다. 새 `tui`가 pre-launch receipt를 출력하고 UUID session으로 시작하는지, 다른 caller cwd에서 `tui <worker-id>`가 저장된 cwd/session/model/role로 resume하는지 검사한다.

  함께 검사할 오류는 existing attach에 `--cwd|--role|--model` 전달, missing stored cwd/session, active/closed worker attach, missing/malformed `result.md`, nonzero TUI exit다.

- [ ] **Step 2: 현재 CLI에서 `tui`가 없는 실패를 확인한다**

  Run: `bash tests/test_glm_agent.sh`

  Expected: unknown command 또는 TUI artifact 부재로 FAIL.

- [ ] **Step 3: TUI lifecycle을 구현한다**

  새 TUI는 `/dev/urandom` 16 bytes로 UUID-format session ID를 만들어 metadata에 먼저 저장하고 turn lock을 획득한다. `claude --session-id` 또는 `claude --resume`을 foreground subshell의 저장 cwd에서 실행한다. `turns/NNNN/mode`, `prompt.md`, `stderr.log`, `result.md`, `exit.meta`를 mode `0600`으로 남기고 TUI 종료 후 durable marker를 검증해 status를 확정한다. 호출자의 cwd는 바꾸지 않는다.

- [ ] **Step 4: TUI와 headless 상호 resume 회귀를 실행한다**

  Run: `bash tests/test_glm_agent.sh`

  Expected: new TUI → headless send → existing TUI attach가 동일 session을 사용하고 전체 PASS.

- [ ] **Step 5: Task 4를 커밋한다**

  ```bash
  git add glm-agent tests/test_glm_agent.sh
  git commit -m "feat: add managed Claude Code TUI sessions"
  ```

### Task 5: plugin bridge와 my-superpowers async orchestration 갱신

**Files:**
- Modify: `agents/explorer.md`
- Modify: `agents/general-purpose.md`
- Modify: `tests/test_plugin.sh`
- Modify: `/Users/h_kang/.claude/skills/my-superpowers/SKILL.md`

**Interfaces:**
- Consumes: `start/send --async`, `wait --timeout 20`, `status/result/cancel/close` CLI.
- Produces: bridge `ACTION=start|send|wait|status|result|cancel|close`; my-superpowers worker receipt ledger와 quota latch policy.

- [ ] **Step 1: agent prompt의 async state machine 실패 테스트를 작성한다**

  `tests/test_plugin.sh`에서 두 agents가 아래 destination을 명시하는지 검사한다.

  ```text
  start -> start --async
  send -> send --async
  wait -> wait --timeout 20
  cancel -> cancel
  ```

  start/send 완료 조건이 `STATUS=RUNNING` receipt 반환이고 semantic 완료는 wait/status의 `DONE|BLOCKED`임을 검사한다. stop request가 known active worker마다 cancel을 호출하고, quota fallback이 persisted terminal response 뒤에만 일어나는 문구도 고정한다.

- [ ] **Step 2: 기존 synchronous agent prompt가 테스트에 실패하는지 확인한다**

  Run: `bash tests/test_plugin.sh`

  Expected: `--async`, `ACTION=wait`, `ACTION=cancel` 계약 부재로 FAIL.

- [ ] **Step 3: 두 custom agents를 목적지향적 async interpreter로 갱신한다**

  validation 규칙에 `wait`와 `cancel`을 추가하고 한 Bash call 원칙을 유지한다. `start|send`는 receipt를 즉시 반환하며 interpreter가 직접 GLM 작업을 수행하거나 결과를 만들어내지 않도록 destination과 성공 조건을 명확히 쓴다.

- [ ] **Step 4: `superpowers:writing-skills`로 my-superpowers provider lifecycle을 갱신한다**

  native/GLM 선택 원칙은 보존하고 GLM dispatch 이후 다음 상태 전이를 추가한다.

  ```text
  ACTION=start|send -> receipt 기록
  ACTION=wait -> bounded monitoring
  DONE|BLOCKED -> RESULT와 repo 재검증
  quota-exhausted -> quota latch + 같은 logical tier native fallback
  stop request -> known active WORKER_ID마다 ACTION=cancel
  ```

  Claude와 Codex가 읽는 canonical/symlink 위치를 실제 discovery 경로로 재검증하고, 한쪽에만 적용되는 중복 사본을 만들지 않는다.

- [ ] **Step 5: plugin 및 skill 정적 검증을 실행한다**

  Run: `bash tests/test_plugin.sh`

  Run: `claude plugin validate --strict .`

  Expected: 전체 PASS, custom agents의 frontmatter는 `model: sonnet`, `tools: Bash, Read`를 유지한다.

- [ ] **Step 6: repository plugin 변경을 커밋한다**

  ```bash
  git add agents/explorer.md agents/general-purpose.md tests/test_plugin.sh
  git commit -m "feat: route GLM workers asynchronously"
  ```

  사용자 범위 skill 파일은 repo commit에 섞지 않고, 적용 경로와 checksum을 작업 결과에 기록한다.

### Task 6: help·README·version 0.4.0 및 release verification

**Files:**
- Modify: `glm-agent`
- Modify: `README.md`
- Modify: `tests/test_glm_agent.sh`
- Modify: `tests/test_plugin.sh`
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `superpowers/specs/2026-09-29-glm-agent-tui-async-design.md`

**Interfaces:**
- Consumes: Tasks 1-5의 public command와 control fields.
- Produces: agent-discoverable `--help`, 사용자 문서, version parity, main 배포 후보.

- [ ] **Step 1: help와 README 계약 실패 테스트를 작성한다**

  `--help`와 README가 다음 command·의미를 포함하는지 검사한다.

  ```text
  tui [creation options] | tui <worker-id>
  start --async | send --async
  wait --timeout | cancel
  RUNNING is a receipt, not completion
  parent Stop does not replace glm-agent cancel
  ```

  CLI/plugin/marketplace가 모두 `0.4.0`인지 parity assertion을 갱신한다.

- [ ] **Step 2: 문서/version 테스트의 실패를 확인한다**

  Run: `bash tests/test_glm_agent.sh && bash tests/test_plugin.sh`

  Expected: old help/README/version 때문에 FAIL.

- [ ] **Step 3: help와 README를 새 workflow에 맞춰 갱신한다**

  async receipt → worker ID 기록 → wait/status → result 검증 → send 또는 cancel → close 순서를 예제로 제시한다. TUI attach가 stored cwd로 자동 이동하는 점, process-group cancel 범위, raw artifact 위치, quota fallback 조건을 문서화한다.

- [ ] **Step 4: version을 원자적으로 0.4.0으로 올린다**

  Run: `bash scripts/bump-version.sh 0.4.0`

  Expected: `VERSION=0.4.0`과 세 version source의 일치.

- [ ] **Step 5: 전체 정적·동적 검증을 실행한다**

  Run: `bash -n glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh`

  Run: `bash tests/test_glm_agent.sh`

  Run: `bash tests/test_plugin.sh`

  Run when installed: `shellcheck glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh`

  Run: `claude plugin validate --strict .`

  Expected: 전부 exit 0. ShellCheck가 설치되지 않았으면 그 사실만 기록하고 나머지 gate를 계속한다.

- [ ] **Step 6: 실제 Claude lifecycle smoke test를 실행한다**

  private test cwd에서 async explorer worker를 시작해 receipt를 즉시 받고 terminal wait까지 관찰한다. 다른 cwd에서 동일 worker TUI를 attach/exit한 뒤 headless send가 동일 session으로 이어지는지 확인한다. quota가 소진됐으면 `quota-exhausted` terminal artifact와 fallback fields를 검증 결과로 기록하며 성공을 가장하지 않는다. API key/session ID는 보고에 출력하지 않는다.

- [ ] **Step 7: release 변경을 커밋한다**

  ```bash
  git add glm-agent README.md tests/test_glm_agent.sh tests/test_plugin.sh \
    .claude-plugin/plugin.json .claude-plugin/marketplace.json \
    superpowers/specs/2026-09-29-glm-agent-tui-async-design.md
  git commit -m "release: prepare glm-agent 0.4.0"
  ```

### Task 7: 최종 리뷰, main 반영, plugin 설치 갱신

**Files:**
- Review: branch 전체 diff
- Runtime update: user-scope Claude Code marketplace/plugin installation

**Interfaces:**
- Consumes: 검증된 0.4.0 branch.
- Produces: `origin/main`의 public 0.4.0과 local installed plugin parity.

- [ ] **Step 1: `superpowers:requesting-code-review`로 whole-branch review를 수행한다**

  base는 branch point의 `origin/main`, head는 현재 branch로 지정하고 특히 lock race, PID reuse, secret leakage, sync regression을 점검한다. finding은 수정 후 해당 task tests와 full suite를 다시 실행한다.

- [ ] **Step 2: completion evidence를 다시 수집한다**

  `superpowers:verification-before-completion`을 사용해 clean status, commit list, test counts, manifest versions, plugin validation output을 현재 실행 결과로 확인한다.

- [ ] **Step 3: 최신 remote main과 fast-forward 가능성을 검증한다**

  ```bash
  git fetch origin
  git merge-base --is-ancestor origin/main HEAD
  git diff --name-only origin/main...HEAD
  ```

  Expected: 승인된 문서·CLI·tests·agents·manifest·README만 diff에 포함된다. remote가 진행됐으면 feature branch를 `origin/main` 위에 rebase하고 full suite를 재실행한다.

- [ ] **Step 4: origin/main에 push한다**

  ```bash
  git push origin HEAD:main
  ```

  Expected: GitHub `powdream-org/glm-agent` main이 현재 release commit을 가리킨다.

- [ ] **Step 5: local marketplace/plugin을 0.4.0으로 갱신하고 검증한다**

  Claude CLI가 제공하는 marketplace update/plugin update command로 installed copy를 갱신한 뒤 installed manifest version과 두 custom agent 내용을 확인한다. command syntax는 실행 시점의 `claude plugin --help`를 먼저 읽어 현재 CLI와 일치시킨다.

- [ ] **Step 6: 최종 결과를 보고한다**

  commit SHA, pushed main SHA, CLI/plugin version, test counts, live smoke 결과, user-scope my-superpowers 적용 경로, 남은 provider quota 제약만 요약한다. API key와 Claude session ID는 포함하지 않는다.
