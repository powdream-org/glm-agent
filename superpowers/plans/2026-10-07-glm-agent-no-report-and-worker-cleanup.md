# glm-agent NO_REPORT 상태와 낡은 worker 자동 정리 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 결과 파일 없이 끝난 turn 을 에러가 아닌 `NO_REPORT` 로 분리하고, `start` 가 낡은 worker 를 자동으로 삭제하게 한다.

**Architecture:** `execute_headless_turn` 의 결과 파일 검사 두 곳(`result-file-missing`, `result-status-invalid`)이 `INVALID` 대신 `finish_no_report_turn` 을 부른다. 이 함수가 `reply.md` 를 쓰고 `meta` 에 `reason`·`reply` 를 저장한다. `print_no_report_fields` 가 `REASON`·`REPLY`·`NEXT` 줄을 낸다. 정리는 `cmd_start` 가 `create_worker` 앞에서 부르는 `cleanup_old_workers` 가 맡는다. dispatch 스크립트는 `NO_REPORT` 를 종료 상태로 인식한다.

**Tech Stack:** Bash 3.2 호환 셸 스크립트, `jq`, `find`, 가짜 `claude` 를 쓰는 자체 TAP 테스트, `shellcheck`.

**Spec:** `superpowers/specs/2026-10-07-glm-agent-no-report-and-worker-cleanup-design.md` (이 리포). 구현자는 spec 과 이 계획을 함께 읽는다.

## Global Constraints

- 작업 위치: worktree `~/dev/git/toridori-inc/worktrees/glm-agent-no-report-and-cleanup`, 브랜치 `feat/no-report-status-and-worker-cleanup`. 아래 명령의 `WT` 는 이 경로다. `cd` 를 쓰지 않고 `git -C "$WT"` 와 절대경로를 쓴다.
- macOS 기본 Bash(3.2)에서 동작한다. 연관 배열과 GNU 전용 옵션을 쓰지 않는다. 시간 조건은 `find -mmin` 만 쓴다.
- 데몬 · MCP · 데이터베이스 · 다른 구현 언어를 도입하지 않는다.
- stdout 은 compact 하게 유지한다. 회신 본문과 원본 JSON 은 worker 디렉터리에 두고 stdout 에는 경로만 낸다.
- API key 와 Claude session ID 는 stdout 에 나오지 않는다.
- `--help` · README · 테스트 · 구현을 함께 맞춘다.
- 동작을 바꾸는 코드는 실패하는 테스트를 먼저 쓴다. 가짜 `claude` · `curl` 만 쓰고 네트워크를 쓰지 않는다.
- `NO_REPORT` 는 `result-file-missing` 과 `result-status-invalid` 에만 붙는다. 종료 코드는 0 이고 `ERROR_KIND` 는 비어 있다. 출력에 `REASON` · `REPLY` · `NEXT` 가 붙는다.
- 정리 기본값: 보관 21일, `GLM_WORKER_RETENTION_DAYS` 로 변경, 0 이면 끔, `start` 때 24 시간에 한 번, 종료 상태(`DONE` · `BLOCKED` · `NO_REPORT` · `INVALID`)만 삭제, `RUNNING` · `NEW` · `meta` 없음 · 이름이 worker-id 형식이 아님 · 잠금 중은 유지.
- 정리는 `start` 의 stdout · stderr 를 바꾸지 않고, 실패해도 `start` 를 막지 않는다.
- 커밋 메시지는 영어로 쓰고 끝에 `Claude-Session` 줄을 붙인다. `--amend` 를 쓰지 않는다. push 와 PR 생성은 User 승인 뒤에 한다.
- 계획 코드와 구현 코드에 주석을 넣지 않는다.
- 버전은 `scripts/bump-version.sh 1.1.0` 으로만 올린다.

## Review Focus

- 다중 행 회신이 stdout 으로 새는 경우: `REPLY` 는 경로만 내고 본문은 `reply.md` 에만 둔다. (Task 1 테스트)
- 심볼릭 링크로 된 worker 디렉터리: 정리가 링크를 따라가 바깥 디렉터리를 지우면 안 된다. (Task 3 테스트)
- 정리 중에 `start` 두 개가 동시에 도는 경우: 둘 다 성공하고 낡은 worker 는 지워진다. (Task 3 테스트)
- 앞에 0 이 붙은 기한 값(`007`): 7 일로 읽는다. (Task 3 테스트)
- dispatch 가 알 수 없는 `NEXT` 값을 받은 경우: `next=inspect-changes` 로 낸다. (Task 4 테스트)

---

### Task 0: spec 보정

설계 검토 뒤 구현 세부에서 정한 두 가지를 spec 에 반영한다.

**Files:**
- Modify: `superpowers/specs/2026-10-07-glm-agent-no-report-and-worker-cleanup-design.md`

**Interfaces:**
- Consumes: 없음
- Produces: 이후 Task 가 따르는 정리 순서(잘못된 기한 값의 스탬프 처리)와 dispatch 회신 출처(`response.json`)

- [ ] **Step 1: 정리 순서 문구 고치기**

`Edit` 으로 아래 두 곳을 바꾼다.

old:
```
1. `GLM_WORKER_RETENTION_DAYS` 를 읽는다. 비어 있으면 21 이다. 숫자(`^[0-9]+$`)가 아니면 `cleanup.log` 에 경고를 쓰고 끝낸다. 0 이면 스탬프도 건드리지 않고 끝낸다.
```
new:
```
1. `GLM_WORKER_RETENTION_DAYS` 를 읽는다. 비어 있으면 21 이다. 0 이면 스탬프도 건드리지 않고 끝낸다.
```

old:
```
3. 스탬프를 지금 시각으로 갱신한다. 스캔 전에 갱신한다. 동시에 뜬 `start` 의 중복 스캔을 줄인다.
```
new:
```
3. 스탬프를 지금 시각으로 갱신한다. 스캔 전에 갱신한다. 동시에 뜬 `start` 의 중복 스캔을 줄인다. 기한이 숫자(`^[0-9]+$`)가 아니면 `cleanup.log` 에 경고를 쓰고 끝낸다. 스탬프를 먼저 갱신하므로 경고는 하루 한 번만 쓴다.
```

- [ ] **Step 2: dispatch 회신 출처 고치기**

old:
```
- `--- Response ---` 블록은 `NO_REPORT` 이고 결과 파일이 없을 때 낸다. 조건은 지금과 같다. 본문은 `REPLY` 파일에서 읽는다.
```
new:
```
- `--- Response ---` 블록은 `NO_REPORT` 이고 결과 파일이 없을 때 낸다. 본문은 지금처럼 `response.json` 에서 읽는다. jq 조건은 CLI 가 `reply.md` 를 쓸 때와 같다.
```

- [ ] **Step 3: 반영 확인**

Run: `grep -c -E '스탬프를 먼저 갱신하므로|지금처럼 .response.json. 에서' "$WT/superpowers/specs/2026-10-07-glm-agent-no-report-and-worker-cleanup-design.md"`
Expected: `2`

- [ ] **Step 4: Commit**

```bash
WT=~/dev/git/toridori-inc/worktrees/glm-agent-no-report-and-cleanup
git -C "$WT" add -- superpowers/specs/2026-10-07-glm-agent-no-report-and-worker-cleanup-design.md
git -C "$WT" commit -m "docs: align the design with the implementation details" -m "Claude-Session: https://claude.ai/code/session_013wnh3pJy9UaLgKDhTwTZDQ" -- superpowers/specs/2026-10-07-glm-agent-no-report-and-worker-cleanup-design.md
```

---

### Task 1: 결과 없는 turn 을 NO_REPORT 로 끝내기

**Files:**
- Modify: `glm-agent` (`print_turn_control` 939행 근처, `invalidate_turn` 뒤, `prepare_turn` 1132행, `execute_headless_turn` 1321~1341행, 도움말 90 · 185~198 · 204~209 · 237~241행)
- Modify: `tests/test_glm_agent.sh` (가짜 `claude` 272행 근처, 도움말 검사 391행 근처, 1606~1629행, 1654행 뒤)
- Modify: `AGENTS.md` (Behavioral invariants)

**Interfaces:**
- Consumes: `meta_update`, `release_worker_lock`, `print_turn_control`, `snapshot_get` (모두 `glm-agent` 에 이미 있다)
- Produces: `write_reply_file <response_file> <reply_file>` (회신이 있으면 0, 없으면 1), `finish_no_report_turn <dir> <turn> <result_file> <response_file> <reason> <generation>` (출력 후 0), `print_no_report_fields <status> <meta>` (`status` 가 `NO_REPORT` 일 때만 `REASON=` `REPLY=` `NEXT=` 세 줄을 낸다). `meta` 키 `reason` 과 `reply`. Task 2 와 Task 3 이 이 이름을 쓴다.

- [ ] **Step 1: 가짜 claude 에 분기 두 개 더하기**

`tests/test_glm_agent.sh` 의 가짜 `claude` 끝부분을 `Edit` 으로 바꾼다.

old:
```
if [[ "$prompt" == *WRONG_SESSION* ]]; then
  session_id="different-session"
fi

printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","result":"ok"}\n' "$session_id"
FAKE
```
new:
```
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
```

- [ ] **Step 2: 도움말 검사 고치기**

`tests/test_glm_agent.sh` 에서 `Edit`.

old:
```
assert_contains 'help documents durable result status' "$help_output" 'STATUS=DONE|BLOCKED|INVALID'
```
new:
```
assert_contains 'help documents durable result status' "$help_output" 'STATUS=DONE|BLOCKED|NO_REPORT|INVALID'
assert_contains 'help documents NO_REPORT' "$help_output" \
  'NO_REPORT The turn ended without a valid result file. The work may be done.'
assert_contains 'help says NO_REPORT is not an error' "$help_output" \
  'This is not an error: do not close the worker or resend the task.'
assert_contains 'help documents the NO_REPORT output keys' "$help_output" \
  'REASON, REPLY, and NEXT'
```

- [ ] **Step 3: 기존 `MISSING_RESULT` · `MALFORMED_RESULT` 검사를 NO_REPORT 기대값으로 바꾸기**

`tests/test_glm_agent.sh` 의 1606~1629행 블록을 `Edit` 으로 통째로 바꾼다.

old:
```
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
```
new:
```
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
```

- [ ] **Step 4: 빈 회신과 다중 행 회신 테스트 더하기**

`tests/test_glm_agent.sh` 에서 `capture "$SCRIPT" start --cwd "$PROJECT" 'close race fixture worker'` 줄 바로 앞에 `Edit` 으로 아래를 넣는다.

old:
```
capture "$SCRIPT" start --cwd "$PROJECT" 'close race fixture worker'
```
new:
```
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

capture "$SCRIPT" start --cwd "$PROJECT" 'close race fixture worker'
```

- [ ] **Step 5: 실패 확인**

Run: `bash "$WT/tests/test_glm_agent.sh" 2>&1 | grep -E '^not ok' | head -20`
Expected: `not ok` 가 여러 줄 나온다. 예: `missing result is not a command failure` 는 `expected [0], got [1]`, `help documents NO_REPORT` 는 `missing [NO_REPORT The turn ended ...]`.

- [ ] **Step 6: 구현 — 새 함수 세 개**

`glm-agent` 에서 `invalidate_turn` 함수 끝(`return 1` 과 `}` 뒤)과 `validate_worker_execution() {` 사이에 `Edit` 으로 넣는다.

old:
```
  printf 'ERROR=%s\n' "$error"
  return 1
}

validate_worker_execution() {
```
new:
```
  printf 'ERROR=%s\n' "$error"
  return 1
}

write_reply_file() {
  local response_file="$1"
  local reply_file="$2"
  local text

  text="$(
    jq -r '
      select(
        type == "object" and .is_error == false
        and (.result | type) == "string"
        and (.result | test("\\S"))
      ) | .result
    ' "$response_file" 2>/dev/null
  )" || return 1
  [[ -n "$text" ]] || return 1
  printf '%s\n' "$text" >"$reply_file"
  chmod 600 "$reply_file"
}

finish_no_report_turn() {
  local dir="$1"
  local turn="$2"
  local result_file="$3"
  local response_file="$4"
  local reason="$5"
  local generation="$6"
  local reply_file="${result_file%/*}/reply.md"

  write_reply_file "$response_file" "$reply_file" || reply_file=""
  meta_update "$dir" status "NO_REPORT" error_kind "" provider_code "" \
    reason "$reason" reply "$reply_file"
  release_worker_lock "$dir" "$generation"
  print_turn_control "$dir" "$turn" "NO_REPORT" "$result_file" "" ""
}

validate_worker_execution() {
```

- [ ] **Step 7: 구현 — 출력 줄**

`glm-agent` 에서 `print_turn_control` 앞에 함수를 더하고, 그 안에서 부른다. 두 번 `Edit` 한다.

old:
```
print_turn_control() {
  local dir="$1"
```
new:
```
print_no_report_fields() {
  local status="$1"
  local meta="$2"
  local reply

  [[ "$status" == "NO_REPORT" ]] || return 0
  reply="$(snapshot_get "$meta" reply)"
  printf 'REASON=%s\n' "$(snapshot_get "$meta" reason)"
  printf 'REPLY=%s\n' "$reply"
  if [[ -n "$reply" ]]; then
    printf '%s\n' 'NEXT=read-reply'
  else
    printf '%s\n' 'NEXT=inspect-changes'
  fi
}

print_turn_control() {
  local dir="$1"
```

old:
```
  printf 'PROVIDER_CODE=%s\n' "$provider_code"
  if [[ "$error_kind" == "quota-exhausted" ]]; then
    printf '%s\n' 'FALLBACK_RECOMMENDED=true'
  else
    printf '%s\n' 'FALLBACK_RECOMMENDED=false'
  fi
}

extract_zai_code() {
```
new:
```
  printf 'PROVIDER_CODE=%s\n' "$provider_code"
  print_no_report_fields "$status" "$meta"
  if [[ "$error_kind" == "quota-exhausted" ]]; then
    printf '%s\n' 'FALLBACK_RECOMMENDED=true'
  else
    printf '%s\n' 'FALLBACK_RECOMMENDED=false'
  fi
}

extract_zai_code() {
```

- [ ] **Step 8: 구현 — 호출 위치 두 곳과 turn 시작 때 키 비우기**

`glm-agent` 에서 `Edit` 세 번.

old:
```
  if [[ ! -s "$result_file" ]]; then
    drain_owned_provider_group "$provider_pgid" "$provider_start" || true
    invalidate_turn "$dir" "$turn" "$result_file" "result-file-missing" \
      "worker-protocol" "" "$generation"
    return 1
  fi
```
new:
```
  if [[ ! -s "$result_file" ]]; then
    drain_owned_provider_group "$provider_pgid" "$provider_start" || true
    finish_no_report_turn "$dir" "$turn" "$result_file" "$response_file" \
      "result-file-missing" "$generation"
    return 0
  fi
```

old:
```
    *)
      drain_owned_provider_group "$provider_pgid" "$provider_start" || true
      invalidate_turn "$dir" "$turn" "$result_file" "result-status-invalid" \
        "worker-protocol" "" "$generation"
      return 1
      ;;
```
new:
```
    *)
      drain_owned_provider_group "$provider_pgid" "$provider_start" || true
      finish_no_report_turn "$dir" "$turn" "$result_file" "$response_file" \
        "result-status-invalid" "$generation"
      return 0
      ;;
```

old:
```
  meta_update "$dir" turn "$turn" status "RUNNING" error_kind "" \
    provider_code ""
```
new:
```
  meta_update "$dir" turn "$turn" status "RUNNING" error_kind "" \
    provider_code "" reason "" reply ""
```

- [ ] **Step 9: 구현 — 도움말**

`glm-agent` 의 도움말 텍스트를 `Edit` 으로 바꾼다. 다섯 곳이다.

(a) old: `        STATUS=DONE|BLOCKED|INVALID`
new: `        STATUS=DONE|BLOCKED|NO_REPORT|INVALID`

(b) old:
```
        FALLBACK_RECOMMENDED=true|false

  start --async [--role <role>]
```
new:
```
        FALLBACK_RECOMMENDED=true|false

      With STATUS=NO_REPORT, the output also carries REASON, REPLY, and NEXT
      before FALLBACK_RECOMMENDED.

  start --async [--role <role>]
```

(c) old:
```
  BLOCKED   The worker produced a valid result ending in STATUS: BLOCKED.
  INVALID   Claude failed, returned malformed data, or violated the result
            protocol. Raw response and stderr files remain available.
```
new:
```
  BLOCKED   The worker produced a valid result ending in STATUS: BLOCKED.
  NO_REPORT The turn ended without a valid result file. The work may be done.
            This is not an error: do not close the worker or resend the task.
            Read REPLY, check the changed files, and judge.
  INVALID   Claude failed or returned malformed data. Raw response and stderr
            files remain available.
```

(d) old:
```
  and make its final line exactly STATUS: DONE or STATUS: BLOCKED. Starting a
  background process alone is not completion. The wrapper classifies missing
  or malformed results and invocation failures as INVALID.
```
new:
```
  and make its final line exactly STATUS: DONE or STATUS: BLOCKED. Starting a
  background process alone is not completion. The wrapper classifies a missing
  or malformed result as NO_REPORT and an invocation failure as INVALID.
```

(e) old:
```
  0  Command succeeded; DONE and BLOCKED are both successful worker turns.
     quota exits 0 for QUOTA_STATUS=OK, even when a window is exhausted.
  1  Claude invocation or worker result protocol failed (STATUS=INVALID).
```
new:
```
  0  Command succeeded; DONE, BLOCKED, and NO_REPORT are successful worker
     turns. quota exits 0 for QUOTA_STATUS=OK, even when a window is exhausted.
  1  Claude invocation or worker response failed (STATUS=INVALID).
```

(f) old: `  3. Read RESULT and inspect the actual changes.`
new: `  3. Read RESULT, or REPLY when STATUS=NO_REPORT, and inspect the actual changes.`

- [ ] **Step 10: AGENTS.md 불변 조건 고치기**

`AGENTS.md` 에서 `Edit`.

old:
```
- Invocation failures and missing or malformed results become `INVALID`.
```
new:
```
- Invocation failures and malformed provider data become `INVALID`. A turn that
  ends without a valid result file becomes `NO_REPORT`.
```

- [ ] **Step 11: 통과 확인**

Run: `bash "$WT/tests/test_glm_agent.sh" 2>&1 | grep -E '^(not ok|# )'`
Expected: `# all N tests passed` 한 줄만 나온다.
다른 테스트가 `STATUS=INVALID` 를 `MISSING_RESULT` 와 엮어 기대하고 있었다면 `not ok` 로 드러난다. 그런 줄은 이 Task 의 기대값에 맞춰 고친다. 이 Task 와 무관한 실패는 고치지 말고 보고한다.

- [ ] **Step 12: Commit**

```bash
WT=~/dev/git/toridori-inc/worktrees/glm-agent-no-report-and-cleanup
git -C "$WT" add -- glm-agent tests/test_glm_agent.sh AGENTS.md
git -C "$WT" status --short
git -C "$WT" commit -m "feat: end a turn without a result file as NO_REPORT" -m "Claude-Session: https://claude.ai/code/session_013wnh3pJy9UaLgKDhTwTZDQ" -- glm-agent tests/test_glm_agent.sh AGENTS.md
```

---

### Task 2: status · wait · cancel · list · send 에서 NO_REPORT 다루기

**Files:**
- Modify: `glm-agent` (`cmd_status` 2080~2097행, `cmd_wait` 1882행, `cmd_cancel` 1924행)
- Modify: `tests/test_glm_agent.sh` (Task 1 이 넣은 `MULTILINE_REPLY` 테스트 뒤)
- Modify: `README.md` (출력 표, STATUS 표, 결과 계약 설명, 종료 코드 표)
- Modify: `agents/explorer.md` 57행, `agents/general-purpose.md` 58행

**Interfaces:**
- Consumes: Task 1 의 `print_no_report_fields <status> <meta>`, `meta` 키 `reason` · `reply`
- Produces: `status` · `wait` · `cancel` 이 `NO_REPORT` 를 종료 상태로 다루고 `REASON` · `REPLY` · `NEXT` 를 낸다. Task 4 의 dispatch 가 `status` 출력의 `NEXT` 를 읽는다.

- [ ] **Step 1: 실패하는 테스트 쓰기**

`tests/test_glm_agent.sh` 에서 `Edit`. Task 1 Step 4 에서 넣은 블록 뒤에 이어 붙인다.

old:
```
assert_not_contains 'stdout carries the reply path and not the reply' "$OUTPUT" 'first reply line'
```
new:
```
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
```

- [ ] **Step 2: 실패 확인**

Run: `bash "$WT/tests/test_glm_agent.sh" 2>&1 | grep -E '^not ok'`
Expected: `status reports the reason`, `wait treats NO_REPORT as terminal`, `cancel on a NO_REPORT worker succeeds` 등이 `not ok` 로 나온다.

- [ ] **Step 3: 구현 — status 출력**

`glm-agent` 의 `cmd_status` 에서 `Edit`.

old:
```
  printf 'ERROR_KIND=%s\n' "$error_kind"
  printf 'PROVIDER_CODE=%s\n' "$provider_code"
  if [[ "$error_kind" == "quota-exhausted" ]]; then
    printf '%s\n' 'FALLBACK_RECOMMENDED=true'
  else
    printf '%s\n' 'FALLBACK_RECOMMENDED=false'
  fi
  printf 'ACTIVE_MODE=%s\n' "$active_mode"
```
new:
```
  printf 'ERROR_KIND=%s\n' "$error_kind"
  printf 'PROVIDER_CODE=%s\n' "$provider_code"
  print_no_report_fields "$status" "$meta"
  if [[ "$error_kind" == "quota-exhausted" ]]; then
    printf '%s\n' 'FALLBACK_RECOMMENDED=true'
  else
    printf '%s\n' 'FALLBACK_RECOMMENDED=false'
  fi
  printf 'ACTIVE_MODE=%s\n' "$active_mode"
```

- [ ] **Step 4: 구현 — wait 와 cancel 의 종료 판정**

`glm-agent` 에서 `Edit` 두 번. 들여쓰기가 다르므로 앞뒤 줄을 포함한다.

old:
```
      case "$status" in
        DONE|BLOCKED|INVALID)
          print_observed_turn "$dir" "$status" "$meta" "$observed_turn"
```
new:
```
      case "$status" in
        DONE|BLOCKED|NO_REPORT|INVALID)
          print_observed_turn "$dir" "$status" "$meta" "$observed_turn"
```

old:
```
    case "$status" in
      DONE|BLOCKED|INVALID)
        print_observed_turn "$dir" "$status" "$WORKER_META_SNAPSHOT"
```
new:
```
    case "$status" in
      DONE|BLOCKED|NO_REPORT|INVALID)
        print_observed_turn "$dir" "$status" "$WORKER_META_SNAPSHOT"
```

- [ ] **Step 5: 통과 확인**

Run: `bash "$WT/tests/test_glm_agent.sh" 2>&1 | grep -E '^(not ok|# )'`
Expected: `# all N tests passed`

- [ ] **Step 6: 에이전트 지침 두 곳 고치기**

`agents/explorer.md` 와 `agents/general-purpose.md` 에서 각각 `Edit`.

old: `(DONE, BLOCKED, or INVALID) together with CANCEL_RESULT=CANCELLED or`
new: `(DONE, BLOCKED, NO_REPORT, or INVALID) together with CANCEL_RESULT=CANCELLED or`

- [ ] **Step 7: README 고치기**

`README.md` 에서 `Edit` 네 번. 문자열이 둘 이상 나오면 앞뒤 줄을 더 넣어 유일하게 만든다.

(a) 출력 필드 표
old:
```
| `STATUS` | `DONE`, `BLOCKED`, or `INVALID` |
| `RESULT` | The absolute path of the result file |
| `ERROR_KIND` | The failure classification, or empty |
| `PROVIDER_CODE` | The Z.ai error code, or empty |
| `FALLBACK_RECOMMENDED` | `true` or `false` |
```
new:
```
| `STATUS` | `DONE`, `BLOCKED`, `NO_REPORT`, or `INVALID` |
| `RESULT` | The absolute path of the result file |
| `ERROR_KIND` | The failure classification, or empty |
| `PROVIDER_CODE` | The Z.ai error code, or empty |
| `REASON` | With `NO_REPORT` only: `result-file-missing` or `result-status-invalid` |
| `REPLY` | With `NO_REPORT` only: the absolute path of the worker's last reply, or empty |
| `NEXT` | With `NO_REPORT` only: `read-reply` when `REPLY` is set, otherwise `inspect-changes` |
| `FALLBACK_RECOMMENDED` | `true` or `false` |
```

(b) STATUS 표
old:
```
| `BLOCKED` | The worker produced a valid result that ends in `STATUS: BLOCKED` |
| `INVALID` | Claude failed, returned malformed data, or violated the result protocol |
```
new:
```
| `BLOCKED` | The worker produced a valid result that ends in `STATUS: BLOCKED` |
| `NO_REPORT` | The turn ended without a valid result file. This is not an error. The work may be done, so read `REPLY` and check the changed files. Do not close the worker or resend the task |
| `INVALID` | Claude failed or returned malformed data |
```

(c) 결과 계약 설명
old:
```
- The wrapper classifies a failed Claude invocation, an invalid response, a
  missing result, and a malformed final status as `INVALID`.
```
new:
```
- The wrapper classifies a failed Claude invocation and an invalid response as
  `INVALID`. It classifies a missing result and a malformed final status as
  `NO_REPORT`.
```

(d) 종료 코드 표
old:
```
| 0 | The command succeeded. `DONE` and `BLOCKED` are both successful turns |
| 1 | The Claude invocation or the worker result protocol failed (`STATUS=INVALID`) |
```
new:
```
| 0 | The command succeeded. `DONE`, `BLOCKED`, and `NO_REPORT` are all successful turns |
| 1 | The Claude invocation or the worker response failed (`STATUS=INVALID`) |
```

- [ ] **Step 8: 확인과 Commit**

Run: `bash "$WT/tests/test_plugin.sh" 2>&1 | grep -E '^(not ok|# )'`
Expected: `# all N tests passed`

```bash
WT=~/dev/git/toridori-inc/worktrees/glm-agent-no-report-and-cleanup
git -C "$WT" add -- glm-agent tests/test_glm_agent.sh README.md agents/explorer.md agents/general-purpose.md
git -C "$WT" commit -m "feat: report NO_REPORT from status, wait, and cancel" -m "Claude-Session: https://claude.ai/code/session_013wnh3pJy9UaLgKDhTwTZDQ" -- glm-agent tests/test_glm_agent.sh README.md agents/explorer.md agents/general-purpose.md
```

---

### Task 3: 낡은 worker 자동 정리

**Files:**
- Modify: `glm-agent` (상단 변수 17행 뒤, `cmd_start` 앞에 함수 세 개, `cmd_start` 1728행 뒤 한 줄, 도움말 ENVIRONMENT)
- Modify: `tests/test_glm_agent.sh` (끝의 `printf '1..%d\n' "$tests"` 앞)
- Modify: `README.md` (Worker state 절, 환경변수 표)

**Interfaces:**
- Consumes: `meta_get <dir> <key>`, `new_active_generation`, `acquire_worker_lock <dir> <mode> <generation>` (실패하면 `die` 로 종료한다), `WORKERS_DIR`, `GLM_AGENT_HOME`
- Produces: 전역 `CLEANUP_STAMP_FILE`, `CLEANUP_LOG_FILE`. 함수 `cleanup_log <message>`, `cleanup_worker <dir>`, `cleanup_old_workers`. `cmd_start` 가 `( cleanup_old_workers ) >/dev/null 2>&1 || true` 로 부른다.

- [ ] **Step 1: 실패하는 테스트 쓰기**

`tests/test_glm_agent.sh` 끝에서 `Edit`.

old:
```
printf '1..%d\n' "$tests"
if ((failures > 0)); then
```
new:
```
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
```

- [ ] **Step 2: 실패 확인**

Run: `bash "$WT/tests/test_glm_agent.sh" 2>&1 | grep -E '^not ok' | head -20`
Expected: `cleanup deletes a DONE worker idle for 22 days` 가 `still present` 로 실패한다. 삭제 코드가 아직 없다.

- [ ] **Step 3: 구현 — 변수**

`glm-agent` 에서 `Edit`.

old:
```
WORKERS_DIR="$GLM_AGENT_HOME/workers"
```
new:
```
WORKERS_DIR="$GLM_AGENT_HOME/workers"
CLEANUP_STAMP_FILE="$GLM_AGENT_HOME/.cleanup-stamp"
CLEANUP_LOG_FILE="$GLM_AGENT_HOME/cleanup.log"
```

- [ ] **Step 4: 구현 — 함수 세 개**

`glm-agent` 에서 `cmd_start` 정의 앞에 `Edit` 으로 넣는다.

old:
```
cmd_start() {
  local model="$CLAUDE_MODEL"
```
new:
```
cleanup_log() {
  {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$CLEANUP_LOG_FILE"
    chmod 600 "$CLEANUP_LOG_FILE"
  } 2>/dev/null || true
}

cleanup_worker() {
  local dir="$1"
  local name
  local status
  local mtime
  local idle_days
  local generation

  name="${dir##*/}"
  [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] || return 0
  [[ -f "$dir/meta" ]] || return 0
  status="$(meta_get "$dir" status)"
  case "$status" in
    DONE|BLOCKED|NO_REPORT|INVALID) ;;
    *) return 0 ;;
  esac
  mtime="$(stat -f '%m' "$dir/meta" 2>/dev/null || stat -c '%Y' "$dir/meta" 2>/dev/null || true)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$(date +%s)"
  idle_days="$((($(date +%s) - mtime) / 86400))"
  generation="$(new_active_generation)"
  acquire_worker_lock "$dir" "cleanup" "$generation"
  rm -rf -- "$dir"
  cleanup_log "deleted worker=$name status=$status idle_days=$idle_days"
}

cleanup_old_workers() {
  local days="${GLM_WORKER_RETENTION_DAYS:-21}"
  local minutes
  local meta_path

  if [[ "$days" =~ ^[0-9]+$ ]] && ((10#$days == 0)); then
    return 0
  fi
  [[ -d "$WORKERS_DIR" ]] || return 0
  if [[ -n "$(find "$CLEANUP_STAMP_FILE" -mmin -1440 2>/dev/null)" ]]; then
    return 0
  fi
  touch "$CLEANUP_STAMP_FILE"
  chmod 600 "$CLEANUP_STAMP_FILE"
  if [[ ! "$days" =~ ^[0-9]+$ ]]; then
    cleanup_log "warn invalid GLM_WORKER_RETENTION_DAYS=$days"
    return 0
  fi
  minutes="$((10#$days * 1440))"
  while IFS= read -r meta_path; do
    (cleanup_worker "${meta_path%/meta}") 2>/dev/null || true
  done < <(find "$WORKERS_DIR" -mindepth 2 -maxdepth 2 -name meta -mmin "+$minutes" 2>/dev/null)
}

cmd_start() {
  local model="$CLAUDE_MODEL"
```

- [ ] **Step 5: 구현 — start 에서 부르기**

`glm-agent` 의 `cmd_start` 에서 `Edit`.

old:
```
  require_system_prompt_file
  local worker_id
  worker_id="$(create_worker "$model" "$role" "$cwd" "$task" "")"
```
new:
```
  require_system_prompt_file
  (cleanup_old_workers) >/dev/null 2>&1 || true
  local worker_id
  worker_id="$(create_worker "$model" "$role" "$cwd" "$task" "")"
```

- [ ] **Step 6: 구현 — 도움말 환경변수**

`glm-agent` 에서 `Edit`.

old:
```
  GLM_ROLE_PROMPTS_DIR
      Directory containing explorer.md and general-purpose.md, read directly
      on every turn. Default: prompts/ next to the executable.
```
new:
```
  GLM_ROLE_PROMPTS_DIR
      Directory containing explorer.md and general-purpose.md, read directly
      on every turn. Default: prompts/ next to the executable.

  GLM_WORKER_RETENTION_DAYS
      Days a finished worker is kept after its last activity. start deletes
      older DONE, BLOCKED, NO_REPORT, and INVALID workers at most once per 24
      hours. Default: 21. 0 turns the cleanup off.
```

- [ ] **Step 7: 도움말 검사 더하기**

`tests/test_glm_agent.sh` 에서 Task 1 Step 2 로 넣은 도움말 검사 바로 뒤에 `Edit`.

old:
```
assert_contains 'help documents the NO_REPORT output keys' "$help_output" \
  'REASON, REPLY, and NEXT'
```
new:
```
assert_contains 'help documents the NO_REPORT output keys' "$help_output" \
  'REASON, REPLY, and NEXT'
assert_contains 'help documents the retention variable' "$help_output" \
  'GLM_WORKER_RETENTION_DAYS'
assert_contains 'help documents the retention default' "$help_output" \
  'Default: 21. 0 turns the cleanup off.'
```

- [ ] **Step 8: 통과 확인**

Run: `bash "$WT/tests/test_glm_agent.sh" 2>&1 | grep -E '^(not ok|# )'`
Expected: `# all N tests passed`
`shellcheck` 경고가 새 함수에서 나는지도 본다: `shellcheck --external-sources "$WT/glm-agent"` 는 경고 0 이어야 한다.

- [ ] **Step 9: README 고치기**

`README.md` 에서 `Edit` 두 번.

old:
```
- `close` only marks a worker closed. The directory and all turn data stay.
```
new:
```
- `close` only marks a worker closed. The directory and all turn data stay.
- `start` deletes a worker that has finished (`DONE`, `BLOCKED`, `NO_REPORT`, or
  `INVALID`) and has seen no activity for `GLM_WORKER_RETENTION_DAYS` days. It
  checks at most once per 24 hours, whether or not the worker is closed.
  - A `RUNNING` or `NEW` worker, a directory without `meta`, and a locked
    worker stay.
  - Each deletion is logged in `~/.glm/cleanup.log`. The cleanup never changes
    the output of `start`.
```

old:
```
| `GLM_ROLE_PROMPTS_DIR` | Names the directory with `explorer.md` and `general-purpose.md`; the default is `prompts/` next to the executable |
```
new:
```
| `GLM_ROLE_PROMPTS_DIR` | Names the directory with `explorer.md` and `general-purpose.md`; the default is `prompts/` next to the executable |
| `GLM_WORKER_RETENTION_DAYS` | Sets how many days a finished worker is kept after its last activity; the default is `21`, and `0` turns the cleanup off |
```

- [ ] **Step 10: Commit**

```bash
WT=~/dev/git/toridori-inc/worktrees/glm-agent-no-report-and-cleanup
git -C "$WT" add -- glm-agent tests/test_glm_agent.sh README.md
git -C "$WT" commit -m "feat: delete finished workers that have been idle for 21 days" -m "Claude-Session: https://claude.ai/code/session_013wnh3pJy9UaLgKDhTwTZDQ" -- glm-agent tests/test_glm_agent.sh README.md
```

---

### Task 4: dispatch 가 NO_REPORT 를 종료 상태로 다루기

**Files:**
- Modify: `scripts/lib/dispatch-wait.sh` (`dd_emit_response_section` 138행, `dd_emit_verdict` 171~199행)
- Modify: `scripts/lib/dispatch-cmds.sh` (62행, 85행)
- Modify: `tests/dispatch/test_response.sh`, `tests/dispatch/test_wait.sh`, `tests/dispatch/test_cmds.sh`
- Modify: `tests/test_plugin.sh` (327행)
- Modify: `skills/dispatch/SKILL.md` (92행 근처 표, 111~114행, 122~123행)
- Modify: `README.md` (dispatch 표와 설명)

**Interfaces:**
- Consumes: Task 2 의 `glm-agent status` 출력 키 `STATUS=NO_REPORT` `NEXT=read-reply|inspect-changes`
- Produces: `GLM_VERDICT ... status=NO_REPORT class=- ... fallback=false next=<read-reply|inspect-changes>`, 종료 코드 0. `dd_emit_response_section <status> <result> <worker> <turn>` (인자 4개로 줄었다).

- [ ] **Step 1: test_response.sh 고치기 — 가짜 상태와 기대 줄**

`tests/dispatch/test_response.sh` 에서 `Edit` 네 번.

(a) 가짜 NO_REPORT 상태 함수 더하기
old:
```
prepare_fake() {
  use_fake_cli
  fake_cli_set quota "$(fake_quota_healthy)"
  fake_cli_set start "$(fake_receipt w-fake 1 sonnet general-purpose RUNNING)"
  fake_cli_set wait $'WORKER_ID=w-fake\nWAIT_RESULT=TERMINAL'
  fake_cli_set status "$(fake_status INVALID '' worker-protocol)"
}
```
new:
```
fake_no_report_status() {
  printf 'WORKER_ID=w-fake\nSTATUS=NO_REPORT\nTURN=1\nMODEL=sonnet\nROLE=general-purpose\nCWD=%s\nCLOSED=false\n' "$PROJECT"
  printf 'RESULT=\nERROR_KIND=\nPROVIDER_CODE=\nREASON=result-file-missing\nREPLY=%s\nNEXT=%s\nFALLBACK_RECOMMENDED=false\nACTIVE_MODE=\nACTIVE_TURN=\n' "$TURN_DIR/reply.md" "${1:-read-reply}"
}

prepare_fake() {
  use_fake_cli
  fake_cli_set quota "$(fake_quota_healthy)"
  fake_cli_set start "$(fake_receipt w-fake 1 sonnet general-purpose RUNNING)"
  fake_cli_set wait $'WORKER_ID=w-fake\nWAIT_RESULT=TERMINAL'
  fake_cli_set status "$(fake_no_report_status)"
}
```

(b) 기대 verdict 줄과 보조 함수
old:
```
protocol_verdict() {
  printf 'GLM_VERDICT label=%s worker=w-fake status=INVALID class=worker-protocol result=- files_changed=na quota_1w_delta=0 fallback=false' "$1"
}
```
new:
```
no_report_verdict() {
  printf 'GLM_VERDICT label=%s worker=w-fake status=NO_REPORT class=- result=- files_changed=na quota_1w_delta=0 fallback=false next=%s' "$1" "${2:-read-reply}"
}
```

old:
```
assert_no_response() {
  assert_eq "$1" "1|$(protocol_verdict "$2")|0" "$RC|$(verdict_of)|$(response_headers)"
}
```
new:
```
assert_no_response() {
  assert_eq "$1" "0|$(no_report_verdict "$2")|0" "$RC|$(verdict_of)|$(response_headers)"
}
```

(c) 첫 회신 테스트
old:
```
assert_eq 'R8 a worker-protocol turn without a result file prints the worker reply right after the verdict' \
  "$(protocol_verdict reply)"$'\n--- Response ---\nTask finished.\nCommitted abc123 in ../other-repo.' \
  "$(sed -n '/^GLM_VERDICT/,$p' <<<"$OUTPUT")"
assert_eq 'R8 the reply section leaves the exit code at 1' 1 "$RC"
```
new:
```
assert_eq 'R8 a NO_REPORT turn without a result file prints the worker reply right after the verdict' \
  "$(no_report_verdict reply)"$'\n--- Response ---\nTask finished.\nCommitted abc123 in ../other-repo.' \
  "$(sed -n '/^GLM_VERDICT/,$p' <<<"$OUTPUT")"
assert_eq 'R8 a NO_REPORT turn exits 0' 0 "$RC"
```

- [ ] **Step 2: test_response.sh 고치기 — INVALID 경로와 새 검사**

`tests/dispatch/test_response.sh` 에서 `Edit` 세 번.

old:
```
fake_cli_set status "$(fake_status INVALID "$FAKE_RESULT" worker-protocol)"
run_wait withresult
assert_eq 'R8 a worker-protocol turn that has a result file prints no response section' "1|0" "$RC|$(response_headers)"

fake_cli_set status "$(fake_status INVALID '' worker-protocol)"
rm -f "$RESPONSE_FILE"
run_wait nofile
```
new:
```
fake_cli_set status "$(fake_status INVALID "$FAKE_RESULT" worker-protocol)"
run_wait withresult
assert_eq 'R8 an INVALID worker-protocol turn that has a result file prints no response section' "1|0" "$RC|$(response_headers)"

fake_cli_set status "$(fake_status INVALID '' worker-protocol)"
run_wait invalidproto
assert_eq 'R8 an INVALID worker-protocol turn without a result file prints no response section' "1|0" "$RC|$(response_headers)"

fake_cli_set status "$(fake_no_report_status inspect-changes)"
run_wait inspect
assert_contains 'R8 a NO_REPORT turn relays next=inspect-changes' "$(verdict_of)" ' next=inspect-changes'

fake_cli_set status "$(fake_no_report_status 'garbage value')"
run_wait oddnext
assert_contains 'R8 an unknown NEXT value falls back to next=inspect-changes' "$(verdict_of)" ' next=inspect-changes'

fake_cli_set status "$(fake_no_report_status)"
rm -f "$RESPONSE_FILE"
run_wait nofile
```

old:
```
assert_eq 'R8 run --wait with a real worker that wrote no result file prints the worker reply' \
  "1|class=worker-protocol|--- Response ---"$'\nok' \
```
new:
```
assert_eq 'R8 run --wait with a real worker that wrote no result file prints the worker reply' \
  "0|class=-|--- Response ---"$'\nok' \
```

그리고 파일 끝쪽의 두 곳 (`send --wait` 와 `attach`) 도 같은 방식으로 바꾼다. 각각 `Edit` 으로 앞 줄을 포함해 유일하게 만든다.

old:
```
assert_eq 'R8 send --wait prints the worker reply of the second turn' \
  "1|class=worker-protocol|--- Response ---"$'\nok' \
```
new:
```
assert_eq 'R8 send --wait prints the worker reply of the second turn' \
  "0|class=-|--- Response ---"$'\nok' \
```

old:
```
assert_eq 'R8 attach prints the same worker reply' \
  "1|class=worker-protocol|--- Response ---"$'\nok' \
```
new:
```
assert_eq 'R8 attach prints the same worker reply' \
  "0|class=-|--- Response ---"$'\nok' \
```

- [ ] **Step 3: test_wait.sh 고치기**

`tests/dispatch/test_wait.sh` 에서 `Edit`.

old:
```
run_wait malformed "$TEST_ROOT/malformed.md"
assert_contains 'a malformed result is classified worker-protocol' \
  "$(verdict_of)" ' class=worker-protocol '
```
new:
```
run_wait malformed "$TEST_ROOT/malformed.md"
assert_contains 'a malformed result is reported as NO_REPORT' \
  "$(verdict_of)" ' status=NO_REPORT class=- '
assert_eq 'a NO_REPORT verdict exits 0' 0 "$RC"
```

- [ ] **Step 4: test_cmds.sh 고치기**

`tests/dispatch/test_cmds.sh` 에서 `Edit` 두 번.

old:
```
make_brief touch.md $'# Task\nTOUCH_TRACKED\n'
```
new:
```
make_brief touch.md $'# Task\nTOUCH_TRACKED\n'
make_brief missing.md $'# Task\nMISSING_RESULT\n'
```

old:
```
assert_eq 'a blocked send never calls the CLI send' 0 "$(($(fake_cli_calls send) - calls_before))"

finish
```
new:
```
assert_eq 'a blocked send never calls the CLI send' 0 "$(($(fake_cli_calls send) - calls_before))"

use_real_cli
next_session
start_label noreport missing.md --wait --poll-seconds 1
assert_eq 'a NO_REPORT turn exits 0' 0 "$RC"
dispatch pending --session "$SESSION"
assert_eq 'pending lists a NO_REPORT worker as terminal-unacked' \
  "GLM_PENDING label=noreport worker=$WORKER state=terminal-unacked status=NO_REPORT" "$OUTPUT"
dispatch ack --session "$SESSION" --label noreport
assert_eq 'ack acknowledges a NO_REPORT worker' "0|GLM_ACK label=noreport" "$RC|$OUTPUT"

finish
```

- [ ] **Step 5: 실패 확인**

Run: `bash "$WT/tests/test_dispatch.sh" 2>&1 | grep -E '^not ok' | head -20`
Expected: `R8 a NO_REPORT turn without a result file prints ...`, `a NO_REPORT verdict exits 0`, `pending lists a NO_REPORT worker ...` 등이 `not ok` 다.

- [ ] **Step 6: 구현 — dispatch-wait.sh**

`scripts/lib/dispatch-wait.sh` 에서 `Edit` 세 번.

old:
```
dd_emit_response_section() {
  local status="$1" class="$2" result="$3" worker="$4" turn="$5" file text
  if [[ "$status" != INVALID || "$class" != worker-protocol || -n "$result" ]]; then
    return 0
  fi
```
new:
```
dd_emit_response_section() {
  local status="$1" result="$2" worker="$3" turn="$4" file text
  if [[ "$status" != NO_REPORT || -n "$result" ]]; then
    return 0
  fi
```

old:
```
  local label="$1" worker="$2" out status class result fallback delta turn
  out="$(dd_cli status "$worker" 2>/dev/null)" || true
  status="$(dd_kv_get "$out" STATUS)"
  case "$status" in
    DONE|BLOCKED|INVALID) ;;
    *) status=INVALID ;;
  esac
```
new:
```
  local label="$1" worker="$2" out status class result fallback delta turn next=""
  out="$(dd_cli status "$worker" 2>/dev/null)" || true
  status="$(dd_kv_get "$out" STATUS)"
  case "$status" in
    DONE|BLOCKED|NO_REPORT|INVALID) ;;
    *) status=INVALID ;;
  esac
  if [[ "$status" == NO_REPORT ]]; then
    next="$(dd_kv_get "$out" NEXT)"
    if [[ "$next" != read-reply && "$next" != inspect-changes ]]; then
      next=inspect-changes
    fi
  fi
```

old:
```
  printf 'GLM_VERDICT label=%s worker=%s status=%s class=%s result=%s files_changed=%s quota_1w_delta=%s fallback=%s\n' \
    "$label" "$worker" "$status" "$class" "$(dd_encode_token "${result:--}")" "$DD_FILES_CHANGED" "$delta" "$fallback"
  dd_emit_response_section "$status" "$class" "$result" "$worker" "$turn"
  dd_emit_result_sections "$result"
  [[ "$status" == DONE ]]
}
```
new:
```
  printf 'GLM_VERDICT label=%s worker=%s status=%s class=%s result=%s files_changed=%s quota_1w_delta=%s fallback=%s%s\n' \
    "$label" "$worker" "$status" "$class" "$(dd_encode_token "${result:--}")" "$DD_FILES_CHANGED" "$delta" "$fallback" "${next:+ next=$next}"
  dd_emit_response_section "$status" "$result" "$worker" "$turn"
  dd_emit_result_sections "$result"
  [[ "$status" == DONE || "$status" == NO_REPORT ]]
}
```

호출 위치가 더 없는지 확인한다.
Run: `grep -rn 'dd_emit_response_section' "$WT/scripts"`
Expected: 정의 1 곳과 호출 1 곳(`dd_emit_verdict` 안)만 나온다.

- [ ] **Step 7: 구현 — dispatch-cmds.sh**

`scripts/lib/dispatch-cmds.sh` 에서 `Edit` 두 번.

old:
```
    case "$status" in
      DONE|BLOCKED|INVALID)
        if [[ "$acked" == true ]]; then
```
new:
```
    case "$status" in
      DONE|BLOCKED|NO_REPORT|INVALID)
        if [[ "$acked" == true ]]; then
```

old:
```
  case "$status" in
    DONE|BLOCKED|INVALID)
      dd_registry_put "$DD_SESSION" "$DD_LABEL" acked true
```
new:
```
  case "$status" in
    DONE|BLOCKED|NO_REPORT|INVALID)
      dd_registry_put "$DD_SESSION" "$DD_LABEL" acked true
```

- [ ] **Step 8: 통과 확인**

Run: `bash "$WT/tests/test_dispatch.sh" 2>&1 | grep -E '^(not ok|# )'`
Expected: `# all N tests passed` (TAP 합계 줄). `not ok` 가 남으면 Step 1~4 의 기대값과 구현을 대조해 고친다.

- [ ] **Step 9: 스킬 문서와 플러그인 계약 테스트 고치기**

`skills/dispatch/SKILL.md` 에서 `Edit` 다섯 번.

(a) verdict 표에 NO_REPORT 행 더하기
old:
```
| `GLM_VERDICT ... status=BLOCKED` | The worker declared itself blocked | Read the result file and judge |
```
new:
```
| `GLM_VERDICT ... status=BLOCKED` | The worker declared itself blocked | Read the result file and judge |
| `GLM_VERDICT ... status=NO_REPORT class=- ... next=<read-reply or inspect-changes>` | The turn ended without a valid result file. This is not an error. The work may be done | Do not close the worker and do not resend the task. When `next=read-reply`, read the `--- Response ---` section and judge from it. When `next=inspect-changes`, check `files_changed` and the working tree yourself. If more is needed, `send` one line to the same worker. The worker may have worked outside `cwd`, in another repository for example |
```

(b) INVALID worker-protocol 행 고치기
old:
```
| `GLM_VERDICT ... status=INVALID class=worker-protocol` | The turn ended without a valid result file. The work may be done | Read the `--- Response ---` section and judge from it. If the reply says the work is done, or `files_changed` is above 0, verify the result and the diff yourself. The worker may have worked outside `cwd`, in another repository for example, so retry only when no Response section is printed |
```
new:
```
| `GLM_VERDICT ... status=INVALID class=worker-protocol` | The response was malformed or its session did not match | The state of the work is unknown. Check `files_changed` and the working tree, log the class, and ask the user before you retry |
```

(c) Response 블록 설명
old:
```
  - A `worker-protocol` turn without a result file prints a `--- Response ---` block right after `GLM_VERDICT` instead.
```
new:
```
  - A `NO_REPORT` turn without a result file prints a `--- Response ---` block right after `GLM_VERDICT` instead.
```

old:
```
  - It prints only when the turn reported no error and the reply is non-empty. `DONE`, `BLOCKED`, and other `INVALID` classes never print it.
- A turn can end `INVALID` with `worker-protocol` after the work is finished. Read the Response section and `files_changed` before you call it a failure.
```
new:
```
  - It prints only when the turn reported no error and the reply is non-empty. `DONE`, `BLOCKED`, and `INVALID` never print it.
- A turn can end `NO_REPORT` after the work is finished. Read the Response section and `files_changed` before you call it a failure. `NO_REPORT` is not a failure.
```

(d) 종료 코드 표
old:
```
| 0 | `GLM_VERDICT status=DONE`; a `run` or `send` without `--wait` that printed `GLM_RECEIPT`; `pending` |
```
new:
```
| 0 | `GLM_VERDICT status=DONE` or `status=NO_REPORT`; a `run` or `send` without `--wait` that printed `GLM_RECEIPT`; `pending` |
```

`tests/test_plugin.sh` 에서 `Edit`.

old:
```
    'timeout: 7200000' CronCreate pending attach worker-protocol quota-exhausted; do
```
new:
```
    'timeout: 7200000' CronCreate pending attach worker-protocol NO_REPORT quota-exhausted; do
```

- [ ] **Step 10: README dispatch 표 고치기**

`README.md` 에서 `Edit` 네 번.

(a) verdict 표
old:
```
| `GLM_VERDICT status=INVALID class=worker-protocol` | The result contract was violated; the work may be done, possibly in another repository. | Read the `--- Response ---` section and decide. Verify the result and the diff when the reply reports completion or `files_changed` is above 0. `files_changed=0` alone does not justify a retry; retry only when no response section prints. |
```
new:
```
| `GLM_VERDICT status=NO_REPORT class=- next=<read-reply or inspect-changes>` | The turn ended without a valid result file. This is not an error. The work may be done, possibly in another repository. | Do not close the worker or resend the task. Read the `--- Response ---` section, or check the working tree when `next=inspect-changes`. Verify the result and the diff when the reply reports completion or `files_changed` is above 0. |
| `GLM_VERDICT status=INVALID class=worker-protocol` | The response was malformed or its session did not match. | The state of the work is unknown. Check `files_changed` and the working tree, then ask the user before a retry. |
```

(b) 필드 표
old:
```
| `status` | `DONE`, `BLOCKED`, or `INVALID` |
| `class` | The worker's `ERROR_KIND`, or `-` when empty |
```
new:
```
| `status` | `DONE`, `BLOCKED`, `NO_REPORT`, or `INVALID` |
| `class` | The worker's `ERROR_KIND`, or `-` when empty |
```

old:
```
| `fallback` | `true` when the CLI reports `FALLBACK_RECOMMENDED=true`, otherwise `false` |
```
new:
```
| `fallback` | `true` when the CLI reports `FALLBACK_RECOMMENDED=true`, otherwise `false` |
| `next` | Only with `NO_REPORT`: `read-reply` or `inspect-changes` |
```

(c) Response 블록과 종료 코드
old:
```
- When a `worker-protocol` turn has no result file, a `--- Response ---` block
  follows `GLM_VERDICT`.
```
new:
```
- When a `NO_REPORT` turn has no result file, a `--- Response ---` block
  follows `GLM_VERDICT`.
```

old:
```
| 0 | `GLM_RECEIPT` without `--wait`, `GLM_VERDICT status=DONE`, `pending`, or a successful `ack` |
```
new:
```
| 0 | `GLM_RECEIPT` without `--wait`, `GLM_VERDICT status=DONE` or `status=NO_REPORT`, `pending`, or a successful `ack` |
```

- [ ] **Step 11: 전체 확인과 Commit**

Run: `bash "$WT/tests/test_plugin.sh" 2>&1 | grep -E '^(not ok|# )'` 그리고 `bash "$WT/tests/test_dispatch.sh" 2>&1 | grep -E '^(not ok|# )'`
Expected: 둘 다 `# all N tests passed`.

```bash
WT=~/dev/git/toridori-inc/worktrees/glm-agent-no-report-and-cleanup
git -C "$WT" add -- scripts/lib/dispatch-wait.sh scripts/lib/dispatch-cmds.sh tests/dispatch/test_response.sh tests/dispatch/test_wait.sh tests/dispatch/test_cmds.sh tests/test_plugin.sh skills/dispatch/SKILL.md README.md
git -C "$WT" commit -m "feat: treat NO_REPORT as a terminal verdict in glm-dispatch" -m "Claude-Session: https://claude.ai/code/session_013wnh3pJy9UaLgKDhTwTZDQ" -- scripts/lib/dispatch-wait.sh scripts/lib/dispatch-cmds.sh tests/dispatch/test_response.sh tests/dispatch/test_wait.sh tests/dispatch/test_cmds.sh tests/test_plugin.sh skills/dispatch/SKILL.md README.md
```

---

### Task 5: 버전 올리기와 전체 검증

**Files:**
- Modify: `glm-agent` (`VERSION`), `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (`scripts/bump-version.sh` 가 고친다)

**Interfaces:**
- Consumes: Task 1~4 의 커밋
- Produces: 버전 1.1.0 이 맞춰진 브랜치. push 와 PR 은 만들지 않는다.

- [ ] **Step 1: 버전 올리기**

Run: `bash "$WT/scripts/bump-version.sh" 1.1.0`
Expected: 오류 없이 끝난다. 이 스크립트는 커밋 · 태그 · push 를 하지 않는다.

- [ ] **Step 2: 세 파일의 버전이 같은지 확인**

Run: `grep -n '^VERSION=' "$WT/glm-agent"; jq -r '.version' "$WT/.claude-plugin/plugin.json"; jq -r '.plugins[] | select(.name == "glm-agent") | .version' "$WT/.claude-plugin/marketplace.json"`
Expected: 세 값이 모두 `1.1.0` 이다.

- [ ] **Step 3: AGENTS.md 의 검증 명령 전부 실행**

Run (순서대로, 하나라도 실패하면 멈추고 원인을 고친다):
```bash
WT=~/dev/git/toridori-inc/worktrees/glm-agent-no-report-and-cleanup
bash "$WT/tests/test_glm_agent.sh" 2>&1 | grep -E '^(not ok|# )'
bash "$WT/tests/test_plugin.sh" 2>&1 | grep -E '^(not ok|# )'
bash "$WT/tests/test_dispatch.sh" 2>&1 | grep -E '^(not ok|# )'
bash -n "$WT/glm-agent" "$WT/scripts/glm-dispatch" "$WT"/scripts/lib/dispatch-*.sh "$WT"/tests/*.sh "$WT"/tests/dispatch/*.sh "$WT/scripts/bump-version.sh"
shellcheck --external-sources --source-path=SCRIPTDIR "$WT/glm-agent" "$WT/scripts/glm-dispatch" "$WT"/scripts/lib/dispatch-*.sh "$WT"/tests/*.sh "$WT"/tests/dispatch/*.sh "$WT/scripts/bump-version.sh"
claude plugin validate --strict "$WT"
```
Expected: 테스트 세 개는 `# all N tests passed`, `bash -n` 과 `shellcheck` 는 출력 없음, `claude plugin validate` 는 통과.

- [ ] **Step 4: 변경 범위 확인**

Run: `git -C "$WT" diff --stat origin/main..HEAD`
Expected: spec 문서, 이 계획, `glm-agent`, 테스트, README, AGENTS.md, `agents/*.md`, `skills/dispatch/SKILL.md`, dispatch 스크립트, 버전 파일만 나온다. 다른 파일이 보이면 원인을 찾아 되돌린다.

- [ ] **Step 5: Commit**

```bash
WT=~/dev/git/toridori-inc/worktrees/glm-agent-no-report-and-cleanup
git -C "$WT" add -- glm-agent .claude-plugin/plugin.json .claude-plugin/marketplace.json
git -C "$WT" commit -m "chore: bump the version to 1.1.0" -m "Claude-Session: https://claude.ai/code/session_013wnh3pJy9UaLgKDhTwTZDQ" -- glm-agent .claude-plugin/plugin.json .claude-plugin/marketplace.json
```

- [ ] **Step 6: User 에게 보고하고 멈춤**

push · draft PR 생성 · 플러그인 적용(marketplace 갱신, 재기동)은 하지 않는다. 검증 결과와 `git log --oneline origin/main..HEAD` 를 User 에게 보고하고 승인을 받는다.
