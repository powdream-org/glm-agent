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
