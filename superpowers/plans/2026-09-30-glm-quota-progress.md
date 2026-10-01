# glm-agent quota 조회 기능 — 작업 원장

- Linear: 없음
- 착수: 2026-09-30
- 대상 리포 / 브랜치: powdream-org/glm-agent / `feat/glm-quota`
- worktree: `/Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota`
- 기준 상태: `origin/main` = `25516ba99f7365d418e458554cb8074bcb18ec1f` (2026-09-30 `git fetch origin` 후 확인, 로컬 `main`과 동일)
- 요청: "glm 의 남은 토큰량을 알려주는 기능을 glm-agent cli와 plugin skill을 만들자"
- 경로 분류: architectural (새 CLI 서브커맨드 + 새 plugin skill = 새 공개 인터페이스, 외부 API 형태 미확정)

---

## 조사 기록

- 2026-09-30 Z.ai 공식 문서(Context7 `/websites/z_ai_devpack`) 조회
  - 관측: 공식 문서는 5시간 한도 + 주간 한도를 설명하고, 소비 현황은 웹 대시보드(`z.ai/manage-apikey/subscription`)에서 보라고만 안내한다. monitor API 자체의 스키마 문서는 찾지 못했다.
- 2026-09-30 Z.ai 공식 Claude Code plugin 소스 확인
  - 명령: `curl -fsSL https://raw.githubusercontent.com/zai-org/zai-coding-plugins/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs`
  - 관측(원문 요지):
    - `quotaLimitUrl = ${baseDomain}/api/monitor/usage/quota/limit` (query parameter 없음)
    - `model-usage`, `tool-usage`는 `?startTime=yyyy-MM-dd HH:mm:ss&endTime=...` (어제 같은 시각 ~ 지금 시각 끝)
    - 헤더: `'Authorization': authToken` (Bearer 접두사 없음, `ANTHROPIC_AUTH_TOKEN` 값 그대로)
    - baseDomain은 `ANTHROPIC_BASE_URL`의 protocol+host. `api.z.ai`면 ZAI, `open.bigmodel.cn`이면 ZHIPU
    - 응답 `json.data.limits[]`: `type == "TOKENS_LIMIT"` → 공식 스크립트는 `percentage`만 노출(라벨 "Token usage(5 Hour)"), `type == "TIME_LIMIT"` → `percentage`, `currentValue`, `usage`(총량), `usageDetails` (라벨 "MCP usage(1 Month)")
  - 해석(미검증): 토큰 한도는 절대 토큰 수가 아니라 백분율로만 제공될 가능성이 높다. 주간 한도가 `limits[]`에 별도 항목으로 오는지, `nextResetTime` 같은 리셋 시각 필드가 있는지는 실제 응답으로 확인 필요.
- 로컬 환경: `~/.glm/.env.auth` 존재, `curl`·`jq`·`node` 사용 가능
- 2026-10-01 00:12 +0900 실제 API probe (User 허가: "허가 (Recommended)" 선택. key는 stdin 헤더로만 전달, 출력·로그에 없음. raw 응답은 세션 스크래치패드 `probe/`에만 저장)
  - 명령: `printf "Authorization: %s\n" "$key" | curl -sS -H @- https://api.z.ai/api/monitor/usage/quota/limit` → `HTTP 200 time=0.178910s`
  - 관측(응답 원문 그대로):
    ```json
    {"code":200,"msg":"Operation successful","data":{"limits":[
      {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":1450,"remaining":549,"percentage":72,"nextResetTime":1790791395020},
      {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":7974,"remaining":2025,"percentage":79,"nextResetTime":1791162764983}
    ],"level":"lite"},"success":true}
    ```
  - `date -r 1790791395` → `2026-10-01T03:03:15+0900`, `date -r 1791162764` → `2026-10-05T10:12:44+0900`
  - 해석(미검증 부분 표시):
    - **공식 plugin 스크립트의 가정(`TOKENS_LIMIT`/`TIME_LIMIT`)과 실제 응답(`CREDIT_LIMIT`)이 다르다.** 공식 스크립트의 type 매핑은 이 계정에서 아무것도 매칭하지 않는다 → type 이름에 의존하는 파싱은 깨지기 쉽다.
    - 단위는 토큰이 아니라 credit이다. `usage`=한도, `currentValue`=사용량, `remaining`=잔여, `percentage`=사용 백분율(2000 중 1450 → 72.5 → 72, 내림으로 보임), `nextResetTime`=epoch ms.
    - `unit`/`number`: 3/5 = 5시간 창, 6/1 = 1주 창으로 추정(리셋까지 남은 시간 약 2h51m / 약 4.4일과 정합). unit 코드표는 미확인.
    - `remaining`(549) ≠ `usage - currentValue`(550): 1 차이. 서버 값의 반올림 방식 미확인 → 서버가 준 `remaining`을 그대로 쓰는 편이 안전.
    - `level`: 요금제 등급(`lite`). MCP용 `TIME_LIMIT` 항목은 이 계정 응답에 없다.
  - 명령: `GET https://api.z.ai/api/monitor/usage/model-usage?startTime=<어제 HH:00:00>&endTime=<오늘 HH:59:59>` → `HTTP 200`
  - 관측: `data` keys = `granularity`("hourly"), `modelCallCount[24]`, `modelDataList[]`(`modelName`, `tokensUsage[24]`, `totalTokens`), `modelSummaryList`, `tokensUsage`, `totalUsage`(`totalModelCallCount`=282, `totalTokensUsage`=35345227, 모델별 `totalTokens`: GLM-5.3=35206505, GLM-5.3-Flash=138722), `x_time`
  - 해석: 토큰 수는 **최근 24시간 사용량**으로만 얻을 수 있다. "남은 토큰"은 API가 주지 않는다. 잔여량은 credit 단위로만 존재한다.

## 결정

- 2026-10-01 용도 = **오케스트레이터 gate** (User 선택. 제시안 중 "둘 다"를 권장했으나 User가 gate 전용을 골랐다). 사람이 읽기 좋은 출력은 부차적이다.
  - 근거(내 판단): 현재 오케스트레이터는 GLM turn이 `ERROR_KIND=quota-exhausted`로 실패한 **뒤에야** native로 전환한다(`agents/*.md`, my-superpowers §6 quota latch). dispatch 전 잔여량을 보면 실패한 turn과 부분 산출물을 줄일 수 있다.
- 참고: bridge agent(`agents/general-purpose.md`)는 `bash "${CLAUDE_PLUGIN_ROOT}/glm-agent" <cmd>` 한 번으로 CLI를 부른다. skill도 같은 경로 규약을 쓴다.
- 2026-10-01 접근 = **B: CLI는 수치만 출력, 판정 기준은 skill 문서** (User 선택). **내 권장(A: CLI가 `QUOTA_STATE`·`DISPATCH_RECOMMENDED` 판정)을 뒤집었다.**
  - 제시했던 안: A(CLI 판정) / B(수치만) / C(start·send 내장 pre-flight) / A+C
  - B를 받아들이는 근거(내 판단): 적정 임계치는 작업 크기·중요도에 달렸고 그것은 오케스트레이터만 안다. GLM turn당 credit 소비를 잰 데이터가 없어 CLI 기본 임계치는 근거 없는 숫자가 된다.
  - B의 비용: 판정 규칙을 hermetic test로 검증할 수 없다. 완화책: CLI가 창별 잔여량·리셋 시각을 계산 없이 비교 가능한 형태로 출력하고, skill은 비교만 하게 한다. A 대비 B의 손해는 modest로 판단.
- 2026-10-01 설계 1/2 (CLI `glm-agent quota`) **User 승인** ("ㅇㅋ"). 요지:
  - `GET <ZAI_BASE_URL의 scheme+host>/api/monitor/usage/quota/limit`, key는 `curl -H @-` stdin 헤더로만 전달, `--connect-timeout 5 --max-time 10`
  - stdout: `QUOTA_STATUS=OK|INVALID`, `PLAN_LEVEL`, `LIMIT_COUNT`, `LIMIT_<n>_{TYPE,WINDOW,TOTAL,USED,REMAINING,USED_PERCENT,RESET_AT}`, `RESPONSE`, `ERROR_KIND`, `PROVIDER_CODE`
  - 서버 값 그대로(계산 금지), WINDOW는 실측 코드만 매핑(3→h, 6→w), 미지 코드는 `u<unit>x<number>`, RESET_AT은 jq `todate` UTC, `limits[]` 전부 출력(TIME_LIMIT 포함)
  - ERROR_KIND: `authentication`(401/403, 1000/1001/1003) · `provider-transient`(네트워크·timeout·5xx·1302/1305) · `provider-error`(기타·`success:false`) · `invalid-response`(파싱 실패·`data.limits` 없음)
  - exit 0=조회 성공(잔여 0이어도) / 1=조회 실패 / 2=사용법·설정
  - raw는 `~/.glm/quota/`에 마지막 1회분 덮어쓰기
  - 제외: 24h 토큰 사용량(`model-usage`) — gate에 불필요(YAGNI)
- 확인한 사실: Claude Code 공식 문서(Context7 `/websites/code_claude`, skills 문서 "Available string substitutions") — plugin skill에서 `${CLAUDE_PLUGIN_ROOT}`는 본문과 `allowed-tools` Bash 규칙 양쪽에서 치환된다. `unit` 코드표는 공개 자료에서 찾지 못함(LogicIncZo/zai-usage README에도 없음).
- 2026-10-01 설계 2/2 (skill·테스트·문서) 제시 → User 응답: "5시간 90퍼센트 주간 98퍼센트로 하자" (나머지 항목에 이의 없음)
  - 기준치: `WINDOW=5h` → `USED_PERCENT >= 90`, `WINDOW=1w` → `USED_PERCENT >= 98`. 내가 제시한 단일 90% 휴리스틱을 User가 창별 값으로 바꿨다.
  - 검산(내 판단): lite(5h 2000 / 1w 10000)에서 5h 10% = 1w 2% = 200 credit → 두 창의 절대 여유분이 같다. 다른 plan에서는 총량이 달라 절대값도 달라진다.
  - 모호성 확정(내가 정함, spec 리뷰에서 User 재확인 대상): 기준치 도달 = **단계형**(작고 범위가 정해진 단일 turn 작업만 GLM, 여러 turn 작업은 native). 완전 차단은 `REMAINING=0`일 때만. 미지 창(`u<unit>x<number>`)은 `REMAINING=0` 규칙만 적용하고 처음 보는 창이라고 보고.
  - skill: `skills/quota/SKILL.md`, `name: quota`, `allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/glm-agent" quota)`, 본문 명령 = 같은 문자열, 1회 실행
  - 판정: INVALID+authentication → native+User 보고 / INVALID 기타 → GLM 진행(fail-open, 사후 fallback이 안전망) / TIME_LIMIT 제외 항목 중 REMAINING=0 → native, 소진 항목 RESET_AT 중 최댓값까지 latch 후 재조회 / 기준치 도달 → 단계형 / 그 외 → GLM. 판정에 쓴 WINDOW·REMAINING·RESET_AT를 보고.
  - bridge agent(`agents/*.md`) 변경 없음
  - 테스트: fake `curl` PATH 주입(네트워크 없음), test_plugin.sh에 SKILL.md 계약(명령 문자열 = allowed-tools 규칙) 추가
  - 문서·버전: `--help`·README·AGENTS.md layout(`skills/`) 동기화, `scripts/bump-version.sh 0.5.0`. push·merge·재설치는 별도 승인.
  - 후속(범위 밖): my-superpowers §6에 "dispatch 전 `glm-agent:quota`" 한 줄 추가 — description만으로는 호출 보장 없음

## 산출물

- 2026-10-01 spec 초안: `superpowers/specs/2026-10-01-glm-quota-design.md` — tech-writer 1석(model sonnet)
  - 좌석 비용(완료 알림 기준): subagent_tokens 163,836 / tool_uses 57 / 688s. **spec 1편에 과다.** 원인(추정): tech-writer의 자체 checker·reflow 반복. 다음 문서 좌석은 설계가 확정됐으면 checker 반복 금지를 브리프에 명시하거나, 수정량이 작으면 메인이 직접 고친다.
  - 메인 재확인: `wc -l` 310행, 절 1~11 존재, TBD/TODO 0, 일본어 0, 5.1 stdout 예시 = 원장 값. 1~4절 원장 대조 일치.
  - 메인 self-review 수정(좌석의 "확인 필요" 5건 + 자체 발견): ① 실패 stdout 4행과 순서 확정 ② `stderr.log` 보관·`RESPONSE` 항상 출력 ③ skill `description` 원문 기입 ④ ERROR_KIND 판정 우선순위 6행 확정 — HTTP 429 추가, provider code는 **기존 `classify_error_kind` 재사용**(1113 등 → `quota-exhausted`) ⑤ 판정표에 `INVALID+quota-exhausted` → native·session latch 행 추가, 미지 창 행을 주석으로 바꿔 "처음 일치 행" 규칙과의 충돌 제거 ⑥ `ZAI_BASE_URL` 기본값·형식 검증(exit 2) ⑦ exit 2 사례·테스트 표 구체화, skill 계약에 description·핵심어 검사 추가
  - ④⑤⑥은 User 승인 설계에 없던 확정이다 → spec 리뷰에서 User 확인 대상
- 2026-10-01 spec `superpowers/specs/2026-10-01-glm-quota-design.md` (`1b52a0a`) **User 승인** ("승인"). 메인 self-review로 추가한 ④ERROR_KIND 우선순위·`classify_error_kind` 재사용 ⑤`INVALID+quota-exhausted` 행 ⑥`ZAI_BASE_URL` 검증, 그리고 기준치 도달 시 단계형 해석까지 함께 승인된 것으로 기록한다. 다음 단계: `superpowers:writing-plans`.
- 2026-10-01 plan 좌석 입력 준비: 메인 스크립트로 발췌 파일 `<scratchpad>/facts-plan.md` 생성 — 955행, 16절(glm-agent 1-260·928-942·1516-1549·2107-끝, test_glm_agent.sh 1-30·296-400·끝 46행, test_plugin.sh 1-130·끝 31행, README Commands·Security·Development, AGENTS.md 1-40, bump-version.sh 1-40, plugin.json, probe fixture 원문)
  - GAPS(의도적 제외): test_glm_agent.sh 31-295(fake claude 본문)·401-(끝-46)(기존 케이스). fake curl은 신규라 불필요.
  - 좌석: general-purpose 1석(model sonnet), 출력 `superpowers/plans/2026-10-01-glm-quota-implementation.md`, 외부 읽기 상한 5회, checker 반복 금지
- 2026-10-01 plan 초안 `superpowers/plans/2026-10-01-glm-quota-implementation.md` — general-purpose 1석(model sonnet)
  - 좌석 비용(완료 알림 기준): subagent_tokens 263,815 / tool_uses 41 / 1305s. 브리프에 없던 **프로토타입 검증**(scratchpad `proto*/`에 plan 코드 적용 후 전체 테스트)을 좌석이 자체 수행 → 비용 증가 원인. 대신 실행 단계의 불확실성이 줄었다.
  - 메인 재확인: 1537행, Task 1~5, TBD 0, bash 3.2 금지 구문 0(규칙 서술 행만 매칭), key가 curl argv에 들어가는 구문 0(256행은 fake curl stdin 검사). `man curl` → "-H @file ... Using @- makes curl read the header file from stdin. Added in 7.55.0." 확인.
  - 메인 독립 실행(`<scratchpad>/proto5`, /bin/bash 3.2): `tests/test_glm_agent.sh` → `1..503 # all 503 tests passed`, `tests/test_plugin.sh` → `1..79 # all 79 tests passed`, `shellcheck` OK, `bash -n` OK, `claude plugin validate --strict .` → `✔ Validation passed`. (기준선 0.4.0: 399 / 57)
  - **좌석 판정 뒤집음**: skill의 exit 2(설정 오류) 처리를 좌석안 fail-open → **native + User 보고**로 변경. 근거: key 미설정·`jq` 없음·`ZAI_BASE_URL` 위반은 GLM worker도 멈춘다(`curl` 없음만 예외). plan 62행·SKILL.md 본문·README 블록, spec 6.2 수정.
  - 좌석 보완 수용(spec에 반영): 제어 문자 → 공백 치환(stdout 줄 위조 방지), null 숫자 → 빈 값, `Accept-Language`·`-sS`·curl 7.55, HTTP 200 + `{}` → `provider-error`(5.3 4행 문자 그대로), 본문은 JSON 객체 정확히 1개일 때만 유효. AGENTS.md 추가 3줄(테스트 설명 2·key-stdin invariant 1) 수용.
  - 주의: `proto5`의 SKILL.md·README는 exit 2 변경 **이전** 문구다. 실행은 plan에서 다시 적용하므로 영향 없음.
- 2026-10-01 plan `1bac08c` **User 승인**, 실행 방식 = **좌석 1개 + 최종 리뷰** (User 선택, 내 권장안). provider = native Claude(my-superpowers §6 "GLM 자체의 수정은 native 우선").
  - 실행 좌석: general-purpose 1석(model sonnet), `superpowers:executing-plans`, Task 1~5(Task 5의 live smoke는 제외 — 메인이 User 허가 후 수행). 보고 파일 `<scratchpad>/exec-report.md`.
- 2026-10-01 실행 좌석 완료 — general-purpose 1석(model sonnet): subagent_tokens 153,270 / tool_uses 48 / 502s. 보고 `<scratchpad>/exec-report.md`(38행), deviation 0, 확인 필요 0.
  - 커밋: `35c4411` feat: add quota command for Z.ai credit limits / `5214ebd` feat: classify quota lookup failures / `f4c13d0` feat: add quota gate skill / `a4e30f9` docs: document quota command and gate skill / `25bd0f4` release: prepare glm-agent 0.5.0
  - 변경 8파일 +817/-7: glm-agent(+189), tests/test_glm_agent.sh(+455), tests/test_plugin.sh(+41), skills/quota/SKILL.md(+65), README(+60), AGENTS.md(10), plugin.json·marketplace.json(버전). `superpowers/` 변경 0, `.superpowers`/`sdd` 디렉토리 생성 0.
  - 메인 독립 검증(worktree, /bin/bash 3.2): `tests/test_glm_agent.sh` → `1..503 # all 503 tests passed` / `tests/test_plugin.sh` → `1..79 # all 79 tests passed` / `bash -n` OK / `shellcheck` OK / `claude plugin validate --strict .` → `✔ Validation passed` / `git diff --check 4cbbfc8..HEAD` OK
  - 버전 3곳 0.5.0 일치(glm-agent:5, plugin.json, marketplace.json). `CLAUDE.md` → `AGENTS.md` symlink 유지. SKILL.md·README에 exit 2 → native 문구 반영 확인.
  - 남은 것: live smoke(User 허가 필요), 최종 독립 리뷰, push·merge·재설치(별도 승인)
- 2026-10-01 13:28 +0900 live smoke (User 허가: "허가 (Recommended)"). 사전 확인: `~/.curlrc`, `$XDG_CONFIG_HOME/.curlrc` 없음, `CURL_HOME` 미설정.
  - 명령: `bash <worktree>/glm-agent quota` → `exit=0`, `QUOTA_STATUS=OK`, `PLAN_LEVEL=lite`, `LIMIT_COUNT=2`, `LIMIT_1_WINDOW=5h TOTAL=2000 USED=0 REMAINING=2000 USED_PERCENT=0 RESET_AT=`(빈 값), `LIMIT_2_WINDOW=1w TOTAL=10000 USED=7974 REMAINING=2025 USED_PERCENT=79 RESET_AT=2026-10-05T01:12:44Z`, `ERROR_KIND=`, stderr 0 byte
  - key 검출(`grep -cF -f <(printf key)`): smoke.out 0 / smoke.err 0 / `~/.glm/quota/response.json` 0 / `~/.glm/quota/stderr.log` 0. 권한: `~/.glm` 700, `~/.glm/quota` 700, 파일 600.
  - **신규 관측**: 5h 창 사용량이 0이면 응답에 `nextResetTime` 키가 없다(`has("nextResetTime")=false`). 해석: 5h 창은 소비 시점부터 시작(공식 문서 "resets 5 hours after consumption"과 정합). CLI는 빈 값 처리 — plan Review Focus 3과 일치.
- 2026-10-01 최종 리뷰 도착 — general-purpose 1석(model opus): subagent_tokens 164,441 / tool_uses 30 / 424s. `<scratchpad>/review-final.md`. 판정 "With fixes", Critical 0 / Important 1 / Minor 8. Important: curl이 `~/.curlrc`를 읽음 → `verbose`면 key가 `quota/stderr.log`에, `fail`이면 401이 `provider-transient`로 바뀜. 리뷰어 제안: curl 첫 인자 `-q`.
