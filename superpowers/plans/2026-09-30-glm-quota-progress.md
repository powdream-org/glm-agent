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
