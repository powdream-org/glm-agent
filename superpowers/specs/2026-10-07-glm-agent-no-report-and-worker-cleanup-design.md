# glm-agent: NO_REPORT 상태와 낡은 worker 자동 정리 — 설계

- 상태: 초안. User 가 2026-10-07 에 설계를 승인했다. spec 검토를 기다린다.
- 기준: `origin/main` = `9b896f9`
- 대상: `glm-agent` CLI, dispatch 스크립트, 문서, 에이전트 지침, 스킬, 테스트
- 작업 원장: `~/dev/git/toridori-inc/superpowers/plans/2026-10-06-glm-agent-worker-cleanup-and-protocol-status-progress.md`

## 1. 목표와 범위

목표는 두 가지다.

1. 결과 파일 없이 끝난 turn 을 에러와 구분한다. 오케스트레이터가 이 turn 뒤에 `close` 와 재발주를 하지 않게 한다.
2. 낡은 worker 를 CLI 가 자동으로 삭제한다.

범위 밖이다.

- `prune` 같은 별도 정리 명령
- 데몬·cron·데이터베이스
- worker 회신의 요약
- `my-superpowers` 스킬 수정 (플러그인이 반영된 뒤 따로 한다)
- README·AGENTS.md 의 `ANTHROPIC_DEFAULT_SONNET_MODEL` 값 불일치 수정. 최신 커밋 `9b896f9` 가 sonnet 을 `glm-5.3-flash[1m]` 로 바꿨다. 문서는 `glm-5.3[1m]` 로 남아 있다.

## 2. 현재 동작

| 항목 | 사실 | 위치 |
|---|---|---|
| 결과 없는 turn | `STATUS=INVALID`, `ERROR_KIND=worker-protocol`, `ERROR=<라벨>` 줄, 종료 코드 1 | `invalidate_turn` 1032행 |
| `worker-protocol` 라벨 4개 | `invalid-response`(1305) · `unexpected-session-id`(1312) · `result-file-missing`(1323) · `result-status-invalid`(1338) | `glm-agent` |
| 실제 발생 | `worker-protocol` 이 난 worker 13 개의 라벨이 전부 `result-file-missing` 이다. 결과 없이 끝난 turn 은 합계 37 개다. 한 worker 는 11 turn 중 8 개, 다른 worker 는 14 turn 중 12 개가 결과 없이 끝났다. | `~/.glm/workers` 집계 (2026-10-07) |
| `close` | `meta` 에 `closed=true` 만 쓴다. 디렉터리를 지우지 않는다. | `cmd_close` 2116행 |
| `list` | worker 전부를 필터 없이 출력한다. | `cmd_list` 2099행 |
| 규모 | worker 230 개, 21MB, 가장 오래된 것 2026-09-28 | `~/.glm/workers` |
| 계약 문구 | AGENTS.md: 「missing or malformed results become `INVALID`」 | `AGENTS.md` |
| dispatch | `GLM_VERDICT` 는 `DONE`·`BLOCKED`·`INVALID` 만 안다. `worker-protocol` 이고 결과가 없으면 `--- Response ---` 블록을 낸다. BLOCKED·INVALID 는 종료 코드 1 이다. | `dispatch-wait.sh` 138·171행, `skills/dispatch/SKILL.md` 92·123행 |

## 3. 결정과 출처

| 결정 | 출처 |
|---|---|
| 결과 없는 turn 을 새 status `NO_REPORT` 로 분리한다 | User 결정 (2026-10-07) |
| `NO_REPORT` 출력에 `REPLY` 와 `NEXT` 줄을 더한다 | User 가 질문한 뒤 수정안을 승인 (2026-10-07) |
| 보관 기한은 21일이고 `close` 여부와 무관하다 | User 결정 (2026-10-07) |
| 정리는 `start` 때 하루 한 번만 한다 | User 결정 (2026-10-07) |
| `NO_REPORT` 의 종료 코드는 0 이다 | 설계안에 표시했고 User 가 「진행」으로 승인 (선례: `quota` 는 창이 소진돼도 0) |
| `RUNNING`·`NEW` 는 지우지 않는다. `GLM_WORKER_RETENTION_DAYS` 로 기한을 바꾸고 0 이면 끈다. 정리 실패는 `start` 를 막지 않는다. 결과는 `~/.glm/cleanup.log` 에 쓴다. `prune` 명령은 만들지 않는다. | 설계안에 표시했고 User 가 「진행」으로 승인 |
| 버전을 1.1.0 으로 올린다 | 이 spec 에서 내가 정한 기본값 |

## 4. 설계 A — NO_REPORT 상태

### 4.1 대상

| 라벨 | 새 status | 종료 코드 |
|---|---|---|
| `result-file-missing` | `NO_REPORT` | 0 |
| `result-status-invalid` | `NO_REPORT` | 0 |
| `invalid-response` | `INVALID` (`ERROR_KIND=worker-protocol`) | 1 |
| `unexpected-session-id` | `INVALID` (`ERROR_KIND=worker-protocol`) | 1 |
| claude 종료 오류 · provider 오류 · 취소 | `INVALID` (변경 없음) | 1 |

`NO_REPORT` 의 뜻: claude 가 정상으로 끝났고 session 도 일치한다. 유효한 결과 보고만 없다. 작업은 끝났을 수 있다.

### 4.2 출력 계약

`start` · `send` · `wait` · `status` · `cancel` 이 같은 키를 낸다.

```
WORKER_ID=…
TURN=3
MODEL=…
ROLE=…
STATUS=NO_REPORT
RESULT=<turns/0003/result.md 경로>
ERROR_KIND=
PROVIDER_CODE=
REASON=result-file-missing
REPLY=<turns/0003/reply.md 절대 경로>
NEXT=read-reply
FALLBACK_RECOMMENDED=false
```

- `NO_REPORT` 는 `ERROR=` 줄을 내지 않는다. `ERROR_KIND` 는 비어 있다.
- `REASON` 은 `result-file-missing` 또는 `result-status-invalid` 이다.
- `NEXT` 는 `REPLY` 가 있으면 `read-reply`, 없으면 `inspect-changes` 이다. `inspect-changes` 는 변경 파일을 직접 확인하라는 뜻이다.
- `REASON` · `REPLY` · `NEXT` 는 `STATUS=NO_REPORT` 일 때만 낸다. 다른 status 의 출력은 바뀌지 않는다.
- stdout 에는 경로만 낸다. 회신 본문은 파일에 둔다. AGENTS.md 의 compact stdout 규칙을 따른다.

### 4.3 저장

- `meta` 에 `reason` 과 `reply` 키를 둔다. 다른 status 로 바뀔 때마다 두 키를 비운다.
- `turns/NNNN/reply.md` 는 `response.json` 의 `.result` 를 저장한 파일이다. 모드는 600 이다.
- `reply.md` 는 아래 조건을 모두 만족할 때만 쓴다. 조건은 `dd_emit_response_section` 의 jq 와 같다.
  - `.is_error == false`
  - `.result` 가 문자열이다
  - `.result` 에 공백이 아닌 글자가 있다
- 조건을 만족하지 못하면 `reply.md` 를 쓰지 않고 `REPLY` 를 비운다.
- `latest_result` 는 바꾸지 않는다. `NO_REPORT` turn 은 이전의 정식 결과를 덮지 않는다. 지금의 `INVALID` 와 같다.

### 4.4 상태를 읽는 곳

- `cmd_wait` 와 `cmd_cancel` 의 종료 상태 목록에 `NO_REPORT` 를 더한다 (1882·1924행).
- `send` 는 `NO_REPORT` worker 를 받는다. 조건은 `INVALID` 와 같다 (closed 가 아니고 Claude session 이 있다).
- 도움말: `STATUS VALUES` 에 `NO_REPORT` 를 더하고, `EXIT STATUS` 의 0 항목에 `NO_REPORT` 를 넣는다. 도움말 90행의 상태 목록도 고친다.
- `list` 는 `STATUS=NO_REPORT` 를 그대로 낸다.

### 4.5 dispatch

- `dd_emit_verdict` 는 `NO_REPORT` 를 인식한다. 지금은 모르는 값을 `INVALID` 로 바꾼다 (`dispatch-wait.sh` 176행).
- `GLM_VERDICT` 는 `status=NO_REPORT class=-` 로 나가고 줄 끝에 `next=read-reply` 또는 `next=inspect-changes` 를 붙인다. 다른 status 의 줄은 바뀌지 않는다.
- `--- Response ---` 블록은 `NO_REPORT` 이고 결과 파일이 없을 때 낸다. 조건은 지금과 같다. 본문은 `REPLY` 파일에서 읽는다.
- `glm-dispatch` 의 종료 코드는 `NO_REPORT` 에서 0 이다.
- `pending` 과 `ack` 의 종료 상태 목록에 `NO_REPORT` 를 더한다 (`dispatch-cmds.sh` 62·85행).

### 4.6 지침 문구

아래 문장을 도움말, `agents/explorer.md`, `agents/general-purpose.md`, `skills/dispatch/SKILL.md`, README 에 적는다.

> `NO_REPORT` 는 에러가 아니다. 결과 보고가 없다는 뜻이다. worker 를 `close` 하지 않고 같은 일을 다시 발주하지 않는다. `REPLY` 를 읽고 변경 파일을 확인해 판정한다. 더 필요하면 같은 worker 에 `send` 로 한 줄만 보낸다.

AGENTS.md 의 불변 조건을 고친다.

- 앞: 「Invocation failures and missing or malformed results become `INVALID`.」
- 뒤: 「Invocation failures and malformed provider data become `INVALID`. A turn that ends without a valid result file becomes `NO_REPORT`.」

## 5. 설계 B — 낡은 worker 자동 정리

### 5.1 실행 시점

`cmd_start` 가 `create_worker` 를 부르기 전에 정리 함수를 한 번 부른다. `start` 와 `start --async` 가 같다. `send` · `list` · `status` 는 정리하지 않는다.

### 5.2 순서

1. `GLM_WORKER_RETENTION_DAYS` 를 읽는다. 비어 있으면 21 이다. 숫자(`^[0-9]+$`)가 아니면 `cleanup.log` 에 경고를 쓰고 끝낸다. 0 이면 스탬프도 건드리지 않고 끝낸다.
2. 스탬프 파일 `$GLM_AGENT_HOME/.cleanup-stamp` 의 수정 시각이 24 시간 안이면 끝낸다.
3. 스탬프를 지금 시각으로 갱신한다. 스캔 전에 갱신한다. 동시에 뜬 `start` 의 중복 스캔을 줄인다.
4. 후보를 모은다: `find "$WORKERS_DIR" -mindepth 2 -maxdepth 2 -name meta -mmin +<기한×1440>`.
5. 후보마다 아래를 확인한다. 하나라도 틀리면 건너뛴다.
   - 디렉터리 이름이 `^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$` 이고 `WORKERS_DIR` 바로 아래에 있다.
   - `meta` 의 status 가 `DONE` · `BLOCKED` · `INVALID` · `NO_REPORT` 중 하나다.
   - worker 잠금을 잡을 수 있다 (`acquire_worker_lock`). 실행 중인 turn 이 있으면 잡을 수 없다.
6. 5 의 잠금 확인부터 삭제까지를 worker 마다 별도 서브셸에서 실행한다.
   - `acquire_worker_lock` 은 잠금에 실패하면 `return` 하지 않고 `die` 로 종료한다 (505~507행).
   - worker 별 서브셸이 그 종료를 받아 해당 worker 만 건너뛴다. 정리 전체는 계속된다.
   - 서브셸의 stderr 는 버린다. `die` 메시지가 `start` 의 stderr 에 새지 않게 한다.
7. 잠금을 잡은 채 디렉터리를 삭제한다. 삭제한 worker 를 `cleanup.log` 에 한 줄 쓴다.
8. 정리 함수의 어떤 실패도 `start` 를 막지 않는다. 함수 전체를 서브셸에서 실행하고 종료 상태를 무시한다.

### 5.3 지우는 것과 지우지 않는 것

| 대상 | 처리 |
|---|---|
| 종료 상태이고 마지막 활동이 기한을 넘은 worker | 삭제. `closed` 여부와 무관 |
| `RUNNING` · `NEW` · 상태를 읽을 수 없는 worker | 유지 |
| `meta` 가 없는 디렉터리 | 유지 (마지막 활동 시각을 알 수 없다) |
| 이름이 worker-id 형식이 아닌 디렉터리 | 유지 |
| 잠금을 잡을 수 없는 worker | 유지 |

마지막 활동 시각은 `meta` 의 수정 시각이다. `meta_update` 가 turn 이 끝날 때 `meta` 를 쓰고, `close` 도 쓴다.

### 5.4 출력과 로그

- `start` 의 stdout·stderr 는 정리 때문에 달라지지 않는다. 영수증 줄을 읽는 쪽을 보호한다.
- `cleanup.log` 는 `$GLM_AGENT_HOME` 아래에 있고 모드는 600 이다. 한 줄 형식: `<UTC 시각> deleted worker=<id> status=<status> idle_days=<n>`. 경고 줄 형식: `<UTC 시각> warn <사유>`.
- 로그 파일에 쓸 수 없어도 `start` 는 성공한다.

### 5.5 구현 제약

- macOS 기본 Bash(3.2)에서 동작한다. 연관 배열을 쓰지 않는다.
- `find -mmin` 만 쓴다. GNU 전용 옵션을 쓰지 않는다.
- 데몬과 상태 데이터베이스를 쓰지 않는다. AGENTS.md 의 Project scope 가 정한다.

## 6. 테스트

AGENTS.md 의 규칙대로 실패하는 테스트를 먼저 쓴다. 테스트는 가짜 `claude` · `curl` 을 쓰고 네트워크를 쓰지 않는다. 시간은 `touch -t` 로 `meta` 의 수정 시각을 바꿔 만든다.

**NO_REPORT** (`tests/test_glm_agent.sh`, 기존 1606~1629행의 기대값을 바꾼다)

- `MISSING_RESULT` → 종료 코드 0, `STATUS=NO_REPORT`, `REASON=result-file-missing`, `ERROR_KIND=` 비어 있음, `FALLBACK_RECOMMENDED=false`, `ERROR=` 줄 없음
- `MALFORMED_RESULT` → `STATUS=NO_REPORT`, `REASON=result-status-invalid`
- 회신이 있으면 `REPLY` 파일 내용이 `.result` 와 같다. 모드는 600 이고 `NEXT=read-reply` 이다
- 회신이 비어 있으면 `REPLY=` 이고 `NEXT=inspect-changes` 이다
- `invalid-response` 와 `unexpected-session-id` 는 `INVALID` · `worker-protocol` · 종료 코드 1 로 남는다
- `status` · `wait` · `cancel` 이 같은 키를 낸다. `wait` 가 `WAIT_RESULT=TERMINAL` 을 낸다
- `NO_REPORT` 뒤 `send` 가 받아들여진다. 이전 정식 결과가 `result` 명령에 남는다
- 이어진 `DONE` turn 에서 `reason` · `reply` 가 비워진다
- `list` 가 `STATUS=NO_REPORT` 를 낸다

**정리** (`tests/test_glm_agent.sh`)

- 22일 된 `DONE` worker 는 삭제되고 `cleanup.log` 에 한 줄이 남는다
- 20일 된 `DONE` worker 는 유지된다
- 22일 된 `closed=true` 의 `INVALID` · `NO_REPORT` worker 는 삭제된다
- 22일 된 `RUNNING` · `NEW` worker 는 유지된다
- 22일 되고 `meta` 가 없는 디렉터리는 유지된다
- 이름이 worker-id 형식이 아닌 디렉터리는 유지된다
- 잠금이 걸린 worker 는 유지된다. 잠긴 worker 가 있어도 다른 낡은 worker 는 삭제된다
- 잠긴 worker 를 건너뛰어도 `start` 의 stderr 에 `die` 메시지가 나오지 않는다
- 스탬프가 24 시간 안이면 아무것도 지우지 않고, 25 시간 전이면 지운다
- `GLM_WORKER_RETENTION_DAYS=0` 이면 지우지 않고 스탬프를 만들지 않는다
- `GLM_WORKER_RETENTION_DAYS=abc` 이면 지우지 않고 `cleanup.log` 에 경고가 남는다
- 정리가 있는 `start` 와 없는 `start` 의 stdout 이 같다
- `cleanup.log` 에 쓸 수 없어도 `start` 가 성공한다

**dispatch · 플러그인** (`tests/dispatch/`, `tests/test_plugin.sh`)

- `GLM_VERDICT` 가 `status=NO_REPORT class=- … next=…` 를 내고 종료 코드가 0 이다
- `--- Response ---` 블록이 `NO_REPORT` 에서 나온다
- `pending` 과 `ack` 가 `NO_REPORT` 를 종료 상태로 다룬다
- 스킬 계약 테스트가 바뀐 `skills/dispatch/SKILL.md` 표와 맞는다

배포 전에 AGENTS.md 의 검증 명령을 전부 실행한다: 세 테스트 스크립트, `bash -n`, `shellcheck`, `claude plugin validate --strict .`.

## 7. 바꾸는 파일

| 파일 | 변경 |
|---|---|
| `glm-agent` | `NO_REPORT` 종료 처리, `reply.md` 쓰기, 출력 키, `meta` 키, wait·cancel 종료 판정, 정리 함수, 도움말 |
| `scripts/lib/dispatch-wait.sh` | verdict 상태 인식, `next=` 필드, Response 블록 조건, 종료 코드 |
| `scripts/lib/dispatch-cmds.sh` | `pending` · `ack` 종료 상태 목록 |
| `skills/dispatch/SKILL.md` | verdict 표, 종료 코드 표, `NO_REPORT` 설명 |
| `agents/explorer.md`, `agents/general-purpose.md` | `NO_REPORT` 처리 문구 |
| `README.md`, `AGENTS.md` | 상태 표, 종료 코드, `GLM_WORKER_RETENTION_DAYS`, 불변 조건 |
| `tests/test_glm_agent.sh`, `tests/test_plugin.sh`, `tests/dispatch/*` | 6절의 테스트 |
| `.claude-plugin/*`, `glm-agent` 의 `VERSION` | `scripts/bump-version.sh 1.1.0` |

## 8. 배포와 효과 확인

1. 브랜치 `feat/no-report-status-and-worker-cleanup` 에서 draft PR 을 만든다.
2. push · PR 생성 · 플러그인 적용(marketplace 갱신, 재기동)은 User 가 승인한 뒤에 한다.
3. 플러그인이 반영되면 `my-superpowers` 6절에 4.6 의 문장을 넣는다.
4. 효과 확인: 반영 뒤 `~/.glm/workers` 에서 같은 집계를 다시 한다. 한 worker 에서 결과 없는 turn 이 연속 3 개 이상이면 지침이 효과가 없다고 본다.

## 9. 알려진 한계

- 오케스트레이터가 재발주하지 않는 것은 출력과 지침 문구로 유도할 뿐이다. 보장하지 못한다.
- `meta` 없는 디렉터리와 `NEW` worker 는 정리되지 않는다.
- 오래된 `RUNNING` 으로 남은 고아 worker 는 `status` 나 `wait` 가 `INVALID`·`interrupted` 로 바꾼 뒤에야 정리 대상이 된다.
- 스탬프가 하루 한 번이라 worker 는 기한 뒤 최대 하루 더 남을 수 있다.
- 기한 안에 있는 worker 의 `reply.md` 는 디스크를 쓴다. 한 turn 의 회신 크기 상한은 두지 않는다.
