# GLM worker Claude Code plugin·Superpowers 라우팅 설계

- 작성일: 2026-09-28
- 대상 버전: `0.2.0`
- 상태: 검토 대기
- 작업 원장:
  `superpowers/plans/2026-09-28-glm-worker-plugin-routing-progress.md`

## 1. 목적

`glm-agent`를 Claude Code marketplace에서 설치할 수 있는 plugin으로 배포하고,
Superpowers SDD가 native Claude subagent와 지속형 GLM worker 중 적합한 실행자를
선택할 수 있게 한다.

성공 조건은 다음과 같다.

1. Claude Code가 plugin의 `glm-agent:glm-worker` custom agent를 발견한다.
2. 하나의 GLM worker에 여러 지시를 보내도 같은 `worker_id`, 작업 디렉터리,
   논리 모델, Claude session이 유지된다.
3. Opus/Sonnet/Haiku 논리 등급을 worker 생성 시 선택할 수 있다.
4. Opus 오케스트레이터가 서로 다른 worktree에서 2~3개 worker를 동시에 돌릴 수
   있다.
5. worktree와 병렬성은 Superpowers SDD가 관리하고 GLM custom agent는 침범하지
   않는다.
6. Z.ai 사용량 소진이 확인되면 같은 논리 등급의 native Claude subagent로
   전환한다.
7. CLI·plugin·marketplace 버전은 불일치 상태로 릴리스될 수 없다.

## 2. 범위와 비범위

### 포함

- 이 리포 자체를 Claude Code marketplace 겸 plugin으로 패키징
- 지속 worker를 조작하는 custom agent 한 개
- CLI의 provider 오류 분류와 compact control-plane 출력 확장
- CLI/plugin/marketplace 버전 동기화 도구와 검증
- 설치·사용·Superpowers 연동 문서
- 사용자 범위 `my-superpowers`의 provider 라우팅 규칙 갱신

### 제외

- MCP server, daemon, database
- `/glm-agent:orchestrate` command 또는 동명의 skill
- custom agent 내부의 worktree 생성·삭제
- GLM worker가 다른 subagent를 직접 생성하는 중첩 오케스트레이션
- API key를 plugin 설정이나 저장소에 보관하는 기능
- GLM-5.3-FlashX를 Coding Plan 기본 모델로 사용하는 기능

## 3. 확인된 외부 제약

- Claude Code plugin은 `.claude-plugin/plugin.json`과 `agents/` 같은 구성 요소를
  하나의 설치 단위로 묶으며, marketplace는
  `.claude-plugin/marketplace.json`에서 plugin source를 가리킨다.
- plugin agent는 `<plugin-name>:<agent-name>`으로 노출된다. 따라서 이 설계의
  agent 식별자는 `glm-agent:glm-worker`다.
- custom subagent 호출은 기본적으로 새 인스턴스를 만들지만, 완료 시 받은 agent
  ID로 같은 subagent를 재개할 수 있다. 재개된 subagent는 이전 대화와 tool call
  기록을 보존한다.
- plugin 내부 파일은 `${CLAUDE_PLUGIN_ROOT}`를 기준으로 참조해야 설치 cache
  위치와 무관하게 동작한다.
- Z.ai 공식 문서상 `glm-5.3-flashx`는 Model API code로는 존재하지만 GLM Coding
  Plan에는 아직 제공되지 않는다. Coding Plan endpoint를 사용하는 이 프로젝트의
  기본 alias에는 `glm-5.3-flash[1m]`을 유지한다.

참고 문서:

- [Claude Code plugins](https://code.claude.com/docs/en/plugins)
- [Claude Code custom subagents](https://code.claude.com/docs/en/sub-agents)
- [Z.ai GLM-5.3-Flash/FlashX](https://docs.z.ai/guides/vlm/glm-5.3-flash)
- [Z.ai errors](https://docs.z.ai/api-reference/api-code)

## 4. 선택한 구조

```text
Superpowers SDD / my-superpowers
  ├─ worktree 생성·선택
  ├─ 태스크 분해·병렬도·리뷰 게이트
  ├─ 논리 등급 선택: opus | sonnet | haiku
  └─ provider 선택
       ├─ native Claude agent
       └─ glm-agent:glm-worker (Haiku bridge)
            └─ ${CLAUDE_PLUGIN_ROOT}/glm-agent
                 └─ Z.ai Claude Code session
                      ├─ turn 1: start
                      ├─ turn 2..N: send --resume
                      └─ 명시적 close
```

### 4.1 하나의 parameterized custom agent

plugin에는 `agents/glm-worker.md` 하나만 둔다. Opus/Sonnet/Haiku별 agent 파일을
세 벌 만들지 않는다. 위임 prompt가 `GLM_MODEL=opus|sonnet|haiku`를 전달하고,
bridge가 첫 turn에서만 `glm-agent start --model <alias>`를 호출한다. 후속 turn은
`send`를 사용하므로 CLI에 저장된 원래 모델을 그대로 재사용한다.

custom agent 자체의 Claude model은 `haiku`로 고정한다. 이 agent는 구현 판단을
하지 않고 CLI를 안전하게 호출하고 control-plane 결과만 돌려주는 얇은 bridge다.
여기에서 선택하는 Haiku는 bridge 실행 비용이며, `GLM_MODEL`은 실제 Z.ai worker
모델이다. 두 값을 혼동하지 않는다.

### 4.2 이중 지속성

지속성은 두 층으로 취급한다.

1. 가능하면 오케스트레이터는 Claude Code가 반환한 custom agent ID로 같은
   `glm-worker` bridge를 재개한다.
2. 실제 작업 문맥의 기준은 CLI가 저장한 `worker_id`와
   `claude_session_id`다. bridge 재개가 불가능해도 새 bridge에 기존
   `WORKER_ID`를 넘기면 `glm-agent send`로 같은 GLM session을 계속한다.

한 turn이 `DONE` 또는 `BLOCKED`가 되었다고 worker를 닫지 않는다. 이 값은 해당
turn 결과의 의미이지 worker lifecycle이 아니다. `close`는 오케스트레이터나
사용자가 명시적으로 요청한 경우에만 실행한다.

### 4.3 병렬 worker

병렬 좌석마다 다음 두 값이 달라야 한다.

- SDD가 준비한 독립 worktree의 절대 `cwd`
- `glm-agent start`가 발급한 독립 `worker_id`

custom agent는 worktree를 만들거나 branch를 바꾸지 않는다. 전달받은 `cwd`를
검증해 CLI에 넘기는 것만 한다. 같은 worktree에 쓰기 worker 둘을 동시에 붙이는
것은 SDD가 금지하거나 직렬화한다.

## 5. plugin 파일 구조

```text
.claude-plugin/
  marketplace.json
  plugin.json
agents/
  glm-worker.md
scripts/
  bump-version.sh
glm-agent
system-prompt.md
tests/
  test_glm_agent.sh
  test_plugin.sh
README.md
AGENTS.md
CLAUDE.md -> AGENTS.md
```

`.claude-plugin/marketplace.json`의 source는 `./`이고, plugin과 marketplace의
이름은 모두 `glm-agent`를 사용한다. plugin에는 v1에서 skill, hook, MCP server를
넣지 않는다. custom agent만으로 필요한 entry point가 생기고, 별도
`/glm-agent:orchestrate`는 Superpowers SDD와 책임이 겹친다.

`agents/glm-worker.md`는 최소한 다음 frontmatter를 사용한다.

```yaml
---
name: glm-worker
description: Run or continue a persistent Z.ai GLM coding worker when the orchestrator explicitly chooses the GLM provider.
tools: Bash, Read
model: haiku
---
```

agent는 plugin 안의 실행 파일을 PATH에서 찾지 않고 다음 절대 기준으로 호출한다.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/glm-agent" ...
```

## 6. bridge 입력·출력 계약

### 6.1 입력

오케스트레이터는 자연어 지시와 함께 다음 필드를 명시한다.

| 필드 | start | send | 의미 |
| --- | --- | --- | --- |
| `ACTION` | `start` | `send` | 실행할 CLI 동작 |
| `GLM_MODEL` | 필수 | 생략 | `opus`, `sonnet`, `haiku` |
| `CWD` | 필수 | 생략 | SDD가 준비한 절대 worktree 경로 |
| `WORKER_ID` | 없음 | 필수 | 지속 GLM worker 식별자 |
| `TASK` | 필수 | 필수 | 이번 turn의 완전한 지시 |

`status`, `result`, `close`도 명시적 `ACTION`으로 허용한다. 필수 필드가 없거나
모델이 세 alias 밖이면 추측하지 않고 호출 전 오류로 반환한다.

### 6.2 출력

bridge의 최종 응답은 설명을 길게 붙이지 않고 다음 control-plane 필드를 그대로
보존한다.

```text
PROVIDER=glm
WORKER_ID=<id>
TURN=<number>
MODEL=<logical-alias>
STATUS=DONE|BLOCKED|INVALID
RESULT=<absolute-result-path>
ERROR_KIND=<empty-or-classification>
PROVIDER_CODE=<empty-or-zai-code>
FALLBACK_RECOMMENDED=true|false
```

API key, Claude session ID, raw response, 전체 stderr는 반환하지 않는다. 자세한
자료는 기존 worker directory에 남긴다. 오케스트레이터는 `RESULT`와 실제 diff,
테스트 결과를 별도로 재확인한다.

## 7. 모델 mapping

검증된 Coding Plan mapping을 유지한다.

| 논리 모델 | Z.ai Claude Code alias target |
| --- | --- |
| `haiku` | `glm-5.3-flash[1m]` |
| `sonnet` | `glm-5.3[1m]` |
| `opus` | `glm-5.3[1m]` |

현재 `sonnet`과 `opus`가 같은 target을 쓰는 것은 의도된 설정이다. 논리 등급은
오케스트레이터의 역할·향후 mapping 변경을 보존한다. `send`에서 모델을 바꾸지
않으며, 다른 모델이 필요하면 새 worker를 시작한다.

`glm-5.3-flashx`는 Coding Plan에 들어올 때까지 기본값이나 fallback target으로
사용하지 않는다. 지원이 확인되면 별도 변경으로 mapping과 실제 smoke test를
함께 갱신한다.

## 8. provider 선택 정책

`my-superpowers`는 Superpowers의 skill 선택 규칙을 대체하지 않는다. skill이
subagent 좌석을 만들기로 결정한 시점마다 provider를 한 번 더 선택한다.

### GLM을 우선 고려

- 범위와 산출물이 명확한 구현·수정 작업
- 테스트나 정적 검사로 결과를 객관적으로 검증할 수 있는 작업
- 독립 worktree에서 수행할 수 있고 외부 승인이 필요 없는 작업
- 큰 코드 문맥을 읽되 최종 판정은 메인 오케스트레이터가 재검증하는 작업

### native Claude를 우선 고려

- 사용자 의도 해석, 설계 ruling, 안전·권한 판단
- provider 자체나 GLM wrapper/plugin을 고치는 작업
- Claude 전용 기능이나 현재 대화 문맥에 강하게 의존하는 작업
- 현재 Claude Code 세션에 연결된 connector/MCP 도구를 사용해야 하는 작업.
  GLM bridge는 `Bash, Read`만 받으며 부모 세션의 MCP 도구·연결·인증 상태를
  내부 GLM session으로 전달하지 않는다.
- GLM이 같은 원인으로 반복 실패했고 quota 문제가 아닌 작업
- 최종 독립 리뷰처럼 provider 다양성이 검증 가치가 되는 작업

선택은 모델 등급과 독립적이다. 예를 들어 “Sonnet 좌석”을 결정한 뒤 native
Sonnet 또는 `GLM_MODEL=sonnet` 중 하나를 고른다. native 호출에는 실제 Agent
`model`을 명시하고, GLM 호출에는 bridge의 Agent `model=haiku`와 prompt의
`GLM_MODEL=<논리 등급>`을 각각 명시한다.

## 9. quota 소진과 fallback

### 9.1 오류 분류

CLI는 `INVALID`의 원인을 compact field로 추가 분류한다. raw 파일은 계속 원본
그대로 보존한다.

| Z.ai code | 분류 | 자동 native fallback |
| --- | --- | --- |
| `1113`, `1308`, `1310`, `1316`–`1321` | `quota-exhausted` | 예 |
| `1302`, `1305` | `provider-transient` | 아니요 |
| `1000`, `1001`, `1003` | `authentication` | 아니요 |
| `1211`, `1311` | `model-unavailable` | 아니요 |
| 그 밖의 API/transport 오류 | `provider-error` | 아니요 |
| result 누락·상태 위반·session mismatch | `worker-protocol` | 아니요 |

HTTP 429만 보고 quota로 판정하지 않는다. 단기 rate limit, 과부하, plan 미지원도
429이기 때문이다. 알려진 Z.ai business code가 있어야 `quota-exhausted`로
판정한다.

### 9.2 fallback 절차

`ERROR_KIND=quota-exhausted`일 때 `my-superpowers`/SDD는 다음을 수행한다.

1. 현재 orchestration session에 `Z.ai quota exhausted` latch를 기록한다.
2. 이후 새 좌석은 Z.ai reset 시각까지 GLM을 시도하지 않고 native로 보낸다.
   reset 시각을 얻지 못하면 현재 orchestration session 동안 유지한다.
3. 실패한 좌석은 요청했던 같은 논리 등급의 native Claude agent로 다시
   dispatch한다.
4. native agent prompt에는 원래 task, worktree `cwd`, GLM `RESULT` 경로와
   마지막 요청을 포함한다. native agent가 GLM 대화 자체를 resume했다고
   주장해서는 안 된다.
5. 기존 GLM worker는 자동 삭제하지 않는다. 오케스트레이터가 fallback handoff를
   확인한 뒤 명시적으로 `close`하여 기록을 보존한다.

`STATUS=BLOCKED`는 정상적인 worker 결과이며 provider failure가 아니다. native로
자동 재실행하지 않고 blocker 내용을 오케스트레이터가 판정한다.

## 10. 버전 동기화

현재 CLI 버전 `0.2.0`을 plugin과 marketplace의 최초 버전으로 사용한다.

- `glm-agent`의 `VERSION`
- `.claude-plugin/plugin.json`의 `version`
- `.claude-plugin/marketplace.json` plugin entry의 `version`

세 값은 릴리스 시 항상 동일해야 한다. `scripts/bump-version.sh <semver>`가 세
파일을 한 번에 갱신하고, `tests/test_plugin.sh`가 불일치를 실패 처리한다. JSON은
설치 전에 정적 version이 필요하므로 런타임 동적 참조를 쓰지 않는다. 자동
commit/tag/push는 bump script의 책임에 넣지 않는다.

## 11. 보안과 권한

- API key는 기존 `~/.glm/.env.auth` 또는 `ZAI_API_KEY`만 사용한다.
- marketplace/plugin manifest, agent prompt, stdout에 key를 넣지 않는다.
- custom agent는 session ID를 사용자나 오케스트레이터에 노출하지 않는다.
- GLM worker가 `--dangerously-skip-permissions`로 실제 작업을 수행한다는 사실을
  README에 계속 명시한다.
- bridge는 전달받은 절대 `cwd`를 사용하고 worktree 바깥 경로를 새로 선택하지
  않는다.
- raw response와 stderr는 기존처럼 mode `0600`으로 보존한다.

## 12. 테스트 전략

### hermetic CLI 테스트

- 각 Z.ai quota code가 `quota-exhausted`와 fallback 권고로 분류되는지 검증
- `1302`, `1305`, `1211`, `1311`, 인증 오류가 quota fallback으로 오분류되지
  않는지 검증
- 기존 start/send/session/model/cwd/result/close 계약의 회귀 검증
- stdout에 API key와 session ID가 없는지 검증

### plugin 테스트

- 두 manifest가 JSON으로 parse되고 필수 metadata가 있는지 검증
- CLI/plugin/marketplace version parity 검증
- `agents/glm-worker.md` frontmatter와 최소 tool/model 설정 검증
- agent prompt에 start/send 지속성, 명시적 close, worktree 비소유,
  `${CLAUDE_PLUGIN_ROOT}` 실행 경로가 들어 있는지 검증
- `my-superpowers` routing 예제에서 connector/MCP가 필요한 태스크가 native
  Claude를 선택하는지 검증
- 지원되는 Claude Code에서는 `claude plugin validate .` 실행

### 실제 smoke test

- `--plugin-dir` 또는 local marketplace install로 agent 발견 확인
- fake Claude로 start → send가 같은 worker/session/cwd/model을 쓰는지 확인
- 자격 증명이 이미 있는 경우에만 GLM Coding Plan으로 짧은 실제 turn 실행
- FlashX는 Coding Plan 지원 전 smoke target에서 제외

## 13. 대안과 기각 이유

### 대안 A: 모델별 custom agent 세 개

`glm-opus-worker`, `glm-sonnet-worker`, `glm-haiku-worker`는 이름만 보면 명확하다.
하지만 prompt가 세 벌로 복제되고, custom agent의 native `model`과 실제 GLM
모델을 혼동하기 쉽고, lifecycle 수정 시 drift가 생긴다. 하나의 bridge와 명시적
`GLM_MODEL`이 더 작은 공개 interface다.

### 대안 B: `/glm-agent:orchestrate` skill 추가

설치 후 눈에 띄는 진입점이라는 장점은 있다. 그러나 task 분해, worktree,
병렬도, 리뷰를 Superpowers SDD와 두 군데에서 결정하게 된다. 중복
오케스트레이션과 상충하는 lifecycle을 피하기 위해 v1에서는 만들지 않는다.

### 대안 C: 모든 GLM 실패를 native로 fallback

작업 완료율은 겉으로 높아 보일 수 있다. 하지만 잘못된 model mapping, 만료된
key, result 계약 버그까지 숨겨 진단 가능성을 낮춘다. 공식 quota code로 확인된
소진에만 자동 fallback하는 쪽이 실패 의미를 보존한다.

## 14. 완료 기준

- public repo에서 marketplace를 추가하고 `glm-agent` plugin을 설치할 수 있다.
- `glm-agent:glm-worker`가 start 후 worker ID를 반환하고, 후속 지시가 같은 GLM
  session을 resume하며, 명시적 close 전까지 살아 있다.
- SDD가 만든 서로 다른 worktree에서 worker 2~3개를 병렬 실행할 수 있다.
- Opus/Sonnet/Haiku 논리 등급을 start 시 선택하고 send가 이를 보존한다.
- quota 소진 code만 native fallback을 유발하고 나머지 오류는 정확히 노출된다.
- `my-superpowers`가 모든 subagent dispatch 전에 provider를 선택하고, GLM 선택
  시 이 plugin agent를 사용하도록 문서화되어 있다.
- 전체 hermetic test, shell syntax, shellcheck, plugin validation이 통과한다.
- README, `--help`, agent prompt, manifests의 동작과 버전이 일치한다.
