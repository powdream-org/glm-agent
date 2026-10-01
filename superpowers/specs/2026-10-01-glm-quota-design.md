# glm-agent quota 조회와 dispatch gate skill — 설계

`glm-agent quota` 서브커맨드와 `glm-agent:quota` skill을 추가하고, 버전을 0.5.0으로 올린다.
서브커맨드는 Z.ai가 주는 credit 한도를 창(window)별 수치로 출력한다.
skill은 그 수치를 보고 오케스트레이터가 GLM과 native Claude 중 한쪽을 고르게 한다.

## 1. 목적과 배경

quota gate는 오케스트레이터가 GLM에 dispatch하기 전에 잔여 credit을 확인하는 단계이다.
이 기능의 용도는 오케스트레이터 gate이다.
사람이 읽기 좋은 출력은 부차적이다.

- 현재 native Claude로의 전환은 GLM turn이 `ERROR_KIND=quota-exhausted`로 실패한 뒤에 일어난다.
  - 근거는 `agents/*.md`와 my-superpowers §6의 quota latch이다.
- dispatch 전에 잔여량을 보면 실패한 turn과 부분 산출물을 줄일 수 있다.
- User는 권장안(gate와 사람용 출력 겸용) 대신 gate 전용을 골랐다.

## 2. 실측 사실

Z.ai quota API는 토큰이 아니라 credit 단위의 창별 한도를 돌려준다.
`model-usage` 엔드포인트가 주는 토큰 수는 최근 24시간 사용량(`granularity`="hourly", 24칸)뿐이다.
응답 스키마는 공식 plugin 소스와 2026-10-01의 실제 probe로 확인했다.
공식 문서는 5시간 한도와 주간 한도를 설명하고, 소비 현황은 웹 대시보드(`z.ai/manage-apikey/subscription`)로 안내한다.

### 2.1 probe 응답

2026-10-01 00:12 +0900에 User 허가를 받아 `https://api.z.ai/api/monitor/usage/quota/limit`을 1회 호출했다.
결과는 HTTP 200, 응답 시간 0.178910초였다.
key는 stdin 헤더로만 전달했다.

```json
{"code":200,"msg":"Operation successful","data":{"limits":[
  {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":1450,"remaining":549,"percentage":72,"nextResetTime":1790791395020},
  {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":7974,"remaining":2025,"percentage":79,"nextResetTime":1791162764983}
],"level":"lite"},"success":true}
```

`usage`는 한도, `currentValue`는 사용량, `remaining`은 잔여, `percentage`는 사용 백분율이다.
`level`은 요금제 등급(`lite`)이다.

| 응답 필드 | 관측과 해석 |
|---|---|
| `remaining` | 5h 창에서 549이고 `usage - currentValue`는 550이다. 반올림 방식 미확인 |
| `percentage` | 2000 중 1450은 72.5이고 출력은 72이다. 내림으로 보인다(추정) |
| `nextResetTime` | epoch ms이다. `date -r 1790791395` → `2026-10-01T03:03:15+0900`, `date -r 1791162764` → `2026-10-05T10:12:44+0900` |
| `unit`, `number` | 3/5 = 5시간 창, 6/1 = 1주 창으로 추정한다. 리셋까지 약 2h51m / 약 4.4일과 맞는다. unit 코드표는 미확인 |

### 2.2 공식 plugin 스크립트와의 차이

공식 스크립트가 가정한 `TOKENS_LIMIT`·`TIME_LIMIT` 대신, 이 계정은 `CREDIT_LIMIT`를 돌려준다.
스크립트는 `zai-org/zai-coding-plugins`의 `plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs`이고 2026-09-30에 조회했다.

| 항목 | 공식 스크립트의 가정 | 이 계정의 응답 |
|---|---|---|
| 5시간 한도 | `TOKENS_LIMIT`에서 `percentage`만 읽음(라벨 "Token usage(5 Hour)") | `CREDIT_LIMIT` 항목(`unit`=3, `number`=5)이 `usage`, `currentValue`, `remaining`, `percentage`, `nextResetTime`을 가짐 |
| MCP 한도 | `TIME_LIMIT`에서 `percentage`, `currentValue`, `usage`, `usageDetails`를 읽음(라벨 "MCP usage(1 Month)") | 해당 항목 없음 |

공식 스크립트의 type 매핑은 이 계정의 어느 항목과도 맞지 않는다.
type 이름에 기대는 파싱은 깨지기 쉬우므로, CLI는 `type`을 해석 없이 그대로 출력한다.

## 3. 범위와 비범위

범위는 `glm-agent quota` 서브커맨드, skill `glm-agent:quota`, 테스트, 문서(`--help`, README, AGENTS.md), 버전 0.5.0이다.
비범위와 각 항목의 처리 위치는 다음과 같다.

| 비범위 | 처리 위치 |
|---|---|
| `model-usage`의 24h 토큰 사용량 | 처리 위치 없음. gate 판정에 필요하지 않다(YAGNI) |
| bridge agent(`agents/*.md`) 변경 | 변경 없음. 기존 사후 fallback이 그대로 동작한다(6.4절) |
| `start`·`send`에 내장하는 pre-flight(C안) | 채택하지 않음. dispatch 전 조회는 skill이 맡는다(6절) |
| push, merge, 재설치 | 별도 승인 |
| my-superpowers §6 수정 | 후속 작업(10절) |

## 4. 결정한 접근

접근은 B이다.
CLI는 수치만 출력하고, 판정 기준은 skill 문서에 둔다.

| 안 | 내용 | 결과 |
|---|---|---|
| A | CLI가 `QUOTA_STATE`·`DISPATCH_RECOMMENDED`를 판정한다 | 권장안이었으나 User가 채택하지 않음 |
| B | CLI는 수치만 출력하고 skill이 판정한다 | User 선택 |
| C, A+C | `start`·`send`에 pre-flight를 내장한다(C), 또는 A와 함께 둔다(A+C) | User가 B를 선택해 제외 |

B의 득실은 다음과 같다.

- 득 — 임계치를 작업 크기와 중요도를 아는 오케스트레이터가 정한다.
- 득 — CLI가 근거 없는 기본 임계치를 갖지 않는다. GLM turn당 credit 소비를 잰 데이터가 없기 때문이다.
- 실 — 판정 규칙을 hermetic test로 검증할 수 없다.
- 완화 — CLI가 창별 잔여량과 리셋 시각을 계산 없이 비교 가능한 형태로 출력한다. skill은 비교만 한다.
- 평가 — A 대비 손해를 modest로 판단했다.

## 5. CLI 설계

`glm-agent quota`는 Z.ai monitor API를 1회 호출하고, 창별 수치를 stdout에 출력한다.
요청의 구성은 다음과 같다.

| 항목 | 값 |
|---|---|
| 요청 | `ZAI_BASE_URL`의 scheme과 host(port 포함) 뒤에 `/api/monitor/usage/quota/limit`을 붙인 URL로 GET. query string 없음 |
| `ZAI_BASE_URL` | 기존 CLI 변수(`glm-agent:20`). 기본값 `https://api.z.ai/api/anthropic`. `^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/|$)`에 맞지 않으면 exit 2 |
| 인증 | `Authorization:` 헤더 한 줄(key 값 그대로, Bearer 접두사 없음)을 stdin으로 `curl -H @-`에 전달 |
| timeout | `--connect-timeout 5 --max-time 10` |
| 의존 도구 | `curl`, `jq` |

### 5.1 stdout

성공 출력의 전체 모양은 다음과 같다.
값은 probe 응답에서 가져왔다.
`RESET_AT`은 UTC로 변환을 마친 값이다.

```text
QUOTA_STATUS=OK
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
RESPONSE=<GLM_AGENT_HOME>/quota/response.json
ERROR_KIND=
PROVIDER_CODE=
```

실패 출력은 다음 네 줄이며 exit 1로 끝난다.
순서는 성공 출력의 꼬리와 같다.

```text
QUOTA_STATUS=INVALID
RESPONSE=<GLM_AGENT_HOME>/quota/response.json
ERROR_KIND=<분류>
PROVIDER_CODE=<응답 code 또는 빈 값>
```

### 5.2 필드 의미

출력 필드는 응답 필드를 다음과 같이 옮긴다.
`n`은 1부터 `LIMIT_COUNT`까지이고 응답의 `limits[]` 순서를 따른다.

| 출력 필드 | 응답 원천 | 변환 |
|---|---|---|
| `PLAN_LEVEL` | `data.level` | 서버 값 그대로 |
| `LIMIT_COUNT` | `data.limits[]` 항목 수 | 항목 수 |
| `LIMIT_n_TYPE` | `type` | 서버 값 그대로 |
| `LIMIT_n_WINDOW` | `unit`, `number` | 아래 매핑 |
| `LIMIT_n_TOTAL` | `usage` | 서버 값 그대로 |
| `LIMIT_n_USED` | `currentValue` | 서버 값 그대로 |
| `LIMIT_n_REMAINING` | `remaining` | 서버 값 그대로(서버의 반올림 방식 미확인) |
| `LIMIT_n_USED_PERCENT` | `percentage` | 서버 값 그대로 |
| `LIMIT_n_RESET_AT` | `nextResetTime` (epoch ms) | 초로 바꿔 jq `todate`로 UTC 문자열 변환 |

- `WINDOW`는 `number`에 단위 문자를 붙여 만든다
  - `unit`=3은 `h`, `unit`=6은 `w`이므로 `5h`, `1w`가 나온다
  - 그 밖의 코드는 `u<unit>x<number>`로 보존한다
  - 이 매핑은 실측한 두 항목에서 추정한 것이다(unit 코드표 미확인)
- `limits[]`의 모든 항목을 `TIME_LIMIT`까지 출력한다

### 5.3 ERROR_KIND

조회 실패는 `ERROR_KIND`로 분류한다.
위에서부터 처음 일치하는 행을 적용한다.

| 순서 | 조건 | ERROR_KIND |
|---|---|---|
| 1 | curl exit ≠ 0 (네트워크 오류, timeout) | `provider-transient` |
| 2 | HTTP 401·403 | `authentication` |
| 3 | HTTP 429·5xx | `provider-transient` |
| 4 | 본문 JSON의 숫자 `code`가 200이 아니거나 `success`가 `true`가 아님 | 기존 `classify_error_kind <code> provider-error` 결과 |
| 5 | HTTP 200인데 JSON 파싱 실패, 또는 `data.limits`가 배열이 아님 | `invalid-response` |
| 6 | 그 밖의 HTTP 비-200 | `provider-error` |

- `PROVIDER_CODE`는 본문 JSON의 숫자 `code`가 200이 아닐 때 그 값이고, 그 외에는 빈 값이다
- 4행은 기존 분류표를 그대로 재사용한다. 1000·1001·1003은 `authentication`, 1302·1305는 `provider-transient`, 1113·1308 등은 `quota-exhausted`, 1211·1311은 `model-unavailable`, 그 밖의 code는 `provider-error`가 된다

### 5.4 종료 코드

| exit | 의미 |
|---|---|
| 0 | 조회 성공. 잔여가 0이어도 0이다 |
| 1 | 조회 실패. `QUOTA_STATUS=INVALID` |
| 2 | 사용법·설정 오류: 인자가 붙음(`quota extra`), key 미설정(`ZAI_API_KEY` 비어 있고 auth file 없음 또는 빈 파일), `curl`·`jq` 없음, `ZAI_BASE_URL` 형식 위반 |

### 5.5 raw 산출물

- 경로는 `<GLM_AGENT_HOME>/quota/response.json`과 `<GLM_AGENT_HOME>/quota/stderr.log`이다 (기본 `~/.glm/quota/`)
- 마지막 1회분만 남고 호출마다 덮어쓴다
- 저장 대상은 응답 본문과 curl의 stderr다. 네트워크 실패로 본문이 없으면 `response.json`은 빈 파일이다
- `RESPONSE`는 성공·실패와 무관하게 항상 출력한다

## 6. skill 설계

`skills/quota/SKILL.md`는 `glm-agent quota`를 1회 실행하고, 출력으로 dispatch 대상을 판정한다.

### 6.1 파일 구성

| frontmatter 키 | 값 |
|---|---|
| `name` | `quota` (plugin 이름과 합쳐 `glm-agent:quota`로 호출) |
| `description` | `Use before dispatching work to glm-agent:explorer or glm-agent:general-purpose, and before returning to GLM after a quota-exhausted fallback, to read the remaining Z.ai GLM Coding Plan quota and choose between a GLM worker and native Claude.` |
| `allowed-tools` | `Bash(bash "${CLAUDE_PLUGIN_ROOT}/glm-agent" quota)` |

본문의 명령은 `bash "${CLAUDE_PLUGIN_ROOT}/glm-agent" quota`이며 `allowed-tools` 규칙 안의 문자열과 같다.
`${CLAUDE_PLUGIN_ROOT}`는 skill 본문과 `allowed-tools`의 Bash 규칙 양쪽에서 치환된다.
출처는 Claude Code 공식 문서 skills의 "Available string substitutions"이다.

### 6.2 판정표

skill은 판정표를 위에서부터 읽고, 처음 일치하는 행을 따른다.

| 순서 | 조건 | 판정 |
|---|---|---|
| 1 | `QUOTA_STATUS=INVALID`이고 `ERROR_KIND=authentication` | native Claude, User에게 보고 |
| 2 | `QUOTA_STATUS=INVALID`이고 `ERROR_KIND=quota-exhausted` | native Claude. reset 시각을 모르므로 현재 orchestration session 동안 latch |
| 3 | `QUOTA_STATUS=INVALID`이고 그 외 `ERROR_KIND` | GLM 진행(fail-open). 사후 fallback이 안전망 |
| 4 | `TIME_LIMIT`가 아닌 항목에 `REMAINING=0` | native Claude. 소진 항목의 `RESET_AT` 중 최댓값까지 latch하고 그 뒤 재조회 |
| 5 | `WINDOW=5h`의 `USED_PERCENT>=90` 또는 `WINDOW=1w`의 `USED_PERCENT>=98` | 단계형: 작고 범위가 정해진 단일 turn 작업만 GLM, 여러 turn 작업은 native Claude |
| 6 | 그 외 | GLM 진행 |

완전 차단은 행 1·2·4에서만 일어난다.
`WINDOW`가 `u<unit>x<number>`인 미지 창에는 행 4만 적용되고 행 5의 기준치는 적용되지 않는다.
미지 창이 있으면 어느 행이 적용되든 처음 보는 창이라고 함께 보고한다.
행 4는 `TIME_LIMIT` 외의 type만 본다.
`TIME_LIMIT`는 공식 스크립트가 "MCP usage(1 Month)"로 표시한 type이며, GLM 호출 한도와 별개로 보인다(추정, 이 계정 응답에 없어 미검증).
skill은 판정에 쓴 `WINDOW`, `REMAINING`, `RESET_AT`을 함께 보고하고, 행 5에서는 `USED_PERCENT`도 보고한다.

### 6.3 기준치

- 5시간 창 90%와 1주 창 98%는 User가 정했다("5시간 90퍼센트 주간 98퍼센트로 하자").
- lite 플랜(5h 2000 / 1w 10000)에서 두 기준치가 남기는 여유는 같다.
  - 5h의 10%는 200 credit이고, 1w의 2%도 200 credit이다.
  - 다른 plan은 총량이 달라서 같은 백분율이 다른 절대 여유가 된다.
- 기준치 도달 시 동작을 단계형으로 정한 것은 설계자의 해석이다.
  - User의 지시에는 도달 시 동작이 적혀 있지 않았다.
  - spec 리뷰에서 User가 재확인한다.

### 6.4 bridge agent

bridge agent(`agents/*.md`)는 현행 그대로 쓴다.

- bridge는 부모가 provider를 고른 뒤 worker ACTION 하나를 CLI 한 번으로 옮긴다
- quota 조회는 provider를 고르기 전에 부모가 skill로 직접 수행한다
- `ERROR_KIND=quota-exhausted`와 `FALLBACK_RECOMMENDED=true`를 부모에게 돌려주는 사후 fallback 경로가 그대로 남는다

## 7. 보안

key는 stdin의 헤더 한 줄로만 curl에 전달된다.

- argv에는 curl 옵션과 URL만 있다
- raw 파일에는 응답 본문만 저장된다
  - 응답 JSON의 키는 `code`, `msg`, `data`, `success`와 `data.limits`, `data.level`이다(probe 관측)
- `~/.glm`은 mode 0700이다

## 8. 테스트

테스트는 fake `curl`을 PATH에 주입해 네트워크와 실제 key 없이 CLI를 검증한다.
AGENTS.md 규칙에 따라 테스트를 먼저 추가하고, 실패를 확인한 뒤 구현한다.

### 8.1 CLI 케이스 (`tests/test_glm_agent.sh`)

fake `curl`은 받은 인자와 stdin을 파일에 기록하고, 케이스가 정한 본문과 status를 돌려준다.

| 케이스 | fake curl의 응답 | 기대 결과 |
|---|---|---|
| 정상 | probe 응답 원문 | 5.1절 stdout 예시와 동일, exit 0 |
| 잔여 0 | `remaining`이 0인 항목 | `LIMIT_n_REMAINING=0`, exit 0 |
| TIME_LIMIT 혼재 | `type`이 `TIME_LIMIT`인 항목 포함 | 모든 항목이 `LIMIT_COUNT`에 세어지고 출력됨 |
| 미지 창 | `unit`이 3·6이 아닌 항목 | `WINDOW=u<unit>x<number>` |
| 인증 | HTTP 401·403, 또는 HTTP 200 + `success:false` + code 1001 | `ERROR_KIND=authentication`, exit 1 |
| 일시 오류 | curl exit 28(timeout)·6(네트워크), HTTP 429·500 | `ERROR_KIND=provider-transient`, exit 1 |
| quota 소진 code | HTTP 200 + `success:false` + code 1113 | `ERROR_KIND=quota-exhausted`, `PROVIDER_CODE=1113`, exit 1 |
| 기타 오류 | `success:false` + 분류표에 없는 code, HTTP 404 | `ERROR_KIND=provider-error`, exit 1 |
| 형식 오류 | JSON이 아닌 본문, `data.limits` 없음 | `ERROR_KIND=invalid-response`, exit 1 |
| 요청 형태 | 기록된 인자와 stdin 검사 | URL은 scheme+host+경로, `--connect-timeout 5 --max-time 10`, key는 stdin에만 나타남 |
| host 추종 | `ZAI_BASE_URL=https://example.test:8443/api/anthropic` | URL이 `https://example.test:8443/api/monitor/usage/quota/limit` |
| raw 보관 | 응답을 달리해 연속 2회 호출 | `response.json`에 마지막 응답이 남음 |
| 사용법·설정 오류 | 인자 초과, key 미설정, `curl` 없음, `ZAI_BASE_URL=ftp://x` | exit 2, stdout 비어 있음 |
| help | `glm-agent --help` | USAGE·COMMANDS·EXIT STATUS에 `quota` 포함 |
| key 노출 검사 | 위 모든 케이스 | stdout·stderr의 key 문자열 검색 결과가 비어 있음 |

### 8.2 skill 계약 (`tests/test_plugin.sh`)

- `skills/quota/SKILL.md`가 존재한다
- frontmatter `name`이 `quota`이다
- `allowed-tools`가 `Bash(bash "${CLAUDE_PLUGIN_ROOT}/glm-agent" quota)`와 정확히 같다
- 본문의 명령 문자열이 `allowed-tools` 규칙 안의 명령과 같다
- `description`이 6.1절 원문과 같다
- 본문이 판정표의 핵심어 `QUOTA_STATUS`, `authentication`, `quota-exhausted`, `fail-open`, `REMAINING=0`, `RESET_AT`, `USED_PERCENT`, `90`, `98`을 담는다

### 8.3 검증 명령과 smoke test

완료 선언 전에 AGENTS.md Testing 절의 검증 명령(`tests/test_glm_agent.sh`, `tests/test_plugin.sh`, `bash -n`, `shellcheck`, `claude plugin validate --strict .`)을 모두 실행한다.

- 최종 diff를 확인하고 문서 예시가 실제 출력과 맞는지 본다
- 실제 Z.ai 호출 smoke test는 1회 실행한다
  - probe 때의 허가와 별개로, 실행 직전에 User 허가를 다시 받는다
  - key는 CLI가 저장된 설정에서 읽고, 출력하거나 열람하지 않는다

## 9. 문서와 버전

- `--help`의 USAGE, COMMANDS, EXIT STATUS에 `quota`를 반영한다
  - COMMANDS의 `Output:` 필드 목록은 `start` 항목과 같은 형식으로 쓴다
- README에 `quota` 명령, 출력 필드, `glm-agent:quota` skill, stdin 헤더 보안 방식을 추가한다
- AGENTS.md의 Repository layout에 `skills/` 항목을 추가한다
  - 편집 대상은 `AGENTS.md`뿐이고, `CLAUDE.md`는 symlink로 유지한다
- 버전은 `scripts/bump-version.sh 0.5.0`으로 올린다
  - CLI, plugin manifest, marketplace entry의 버전이 같아야 한다

## 10. 후속 작업

my-superpowers §6에 "dispatch 전 `glm-agent:quota`" 한 줄을 추가한다.
skill의 description만으로는 오케스트레이터가 호출한다는 보장이 없기 때문이다.

## 11. 열린 질문

- unit 코드표
  - `unit`=3과 6의 의미는 리셋 시각과의 정합에서 추정했다
  - 공개 자료(LogicIncZo/zai-usage README 포함)에서 코드표를 찾지 못했다
- `remaining`의 반올림
  - probe에서 `remaining`은 `usage - currentValue`보다 1 작다 (549 대 550, 2025 대 2026)
  - CLI는 서버 값을 그대로 출력하므로 출력은 이 차이의 영향을 받지 않는다
- 다른 plan의 `TOKENS_LIMIT`(관측한 계정은 lite 하나)
  - 공식 스크립트가 가정한 `TOKENS_LIMIT`를 다른 plan이 돌려주는지는 확인하지 못했다
  - 돌려주는 경우의 필드 구성은 알 수 없다(공식 스크립트는 `percentage`만 읽는다)
