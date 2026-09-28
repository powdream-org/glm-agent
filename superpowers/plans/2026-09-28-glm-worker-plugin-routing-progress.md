# GLM worker 플러그인·모델 라우팅 — 작업 원장

- 착수: 2026-09-28
- 대상 리포 / 브랜치: `powdream-org/glm-agent` / `main`
- 기준 상태: `origin/main` = `33fb069` (`Add MIT license`)
- 설계 문서: `superpowers/specs/2026-09-28-glm-worker-plugin-routing-design.md`
- 구현 계획: spec 승인 후 `superpowers/plans/`에 별도 작성

---

## 2026-09-28

### 확정된 요구사항

- Claude Code용 marketplace와 plugin을 `glm-agent` 리포에 함께 배포한다.
- CLI, plugin manifest, marketplace entry의 버전은 항상 함께 올린다.
- plugin은 Opus/Sonnet/Haiku 역할의 GLM worker를 지속 세션으로 제공한다.
- worker는 첫 지시 뒤 자동 종료하지 않는다. 명시적으로 닫기 전까지 같은
  `worker_id`와 Claude session을 후속 지시에 재사용한다.
- worktree 생성·격리·병렬 실행·리뷰 순서는 GLM custom agent가 아니라
  Superpowers SDD 오케스트레이터가 소유한다.
- `/glm-agent:orchestrate`는 만들지 않는다. 기존 Superpowers 오케스트레이션과
  역할이 중복되기 때문이다.
- `my-superpowers`는 각 subagent 좌석마다 native Claude와 GLM worker 중 하나를
  선택한다.
- Z.ai 사용량 한도가 소진된 경우에는 요청했던 같은 논리 등급의 native Claude
  subagent로 전환한다.
- Bash wrapper v1을 유지하며 MCP는 도입하지 않는다.

### 조사 결과

- 현재 리포는 CLI `0.2.0`, `system-prompt.md`, hermetic Bash 테스트로 구성되어
  있고 marketplace/plugin 파일은 아직 없다.
- Claude Code plugin은 `.claude-plugin/plugin.json`과 루트 `agents/`를 자동
  발견한다. plugin agent는 `glm-agent:glm-worker` 이름으로 노출할 수 있다.
- custom subagent는 완료 후 받은 agent ID로 재개할 수 있다. 별도로 GLM CLI의
  `worker_id`도 보존하므로 bridge subagent가 사라져도 GLM session을 복구할 수
  있다.
- Z.ai 공식 오류 코드에서 사용량 소진은 `1113`, `1308`, `1310`,
  `1316`–`1321`이다. `1302`(단기 rate limit), `1305`(일시적 과부하),
  `1311`(현재 plan의 모델 미지원)은 영구적인 사용량 소진과 구분해야 한다.
- Z.ai 문서상 `glm-5.3-flashx`는 Model API에는 존재하지만 GLM Coding Plan에는
  아직 제공되지 않는다. 따라서 현재 Coding Plan 기본 alias에는 넣지 않는다.

### 결정

- plugin custom agent는 모델별로 세 파일을 복제하지 않고 하나의
  `glm-worker` bridge로 만든다. 목표 논리 모델(`opus|sonnet|haiku`)은 위임
  prompt에서 받아 `glm-agent start --model`에 전달하고 이후 turn에서는 저장된
  모델을 재사용한다.
- native/GLM provider 선택과 fallback은 `my-superpowers`/SDD가 맡고,
  `glm-worker`는 선택된 GLM worker의 start/send/result/status/close만 맡는다.
- 자동 fallback은 명시적으로 분류된 quota exhaustion에만 적용한다. 인증,
  잘못된 모델, 결과 계약 위반, 사용자 작업의 `BLOCKED`는 숨기지 않고 상위
  오케스트레이터에 반환한다.

### 게이트 기록

- `git diff --cached --check` → `new blank line at EOF`로 첫 시도 실패. 파일 끝의
  불필요한 빈 줄을 제거하고 재검사한다.
- 원장 첫 커밋: `253d9bc` (`docs: open the GLM worker plugin ledger`).
- 설계 문서 작성:
  `superpowers/specs/2026-09-28-glm-worker-plugin-routing-design.md` (369행).
- spec self-review:
  - `TBD|TODO|implement later` placeholder 검색 결과 없음.
  - CLI/plugin/marketplace version을 `0.2.0`으로 맞추고 parity test와 단일 bump
    script를 두는 것으로 일관성 확인.
  - custom agent가 worktree를 소유하지 않으며 SDD가 병렬성과 provider routing을
    소유하는 것으로 책임 경계 확인.
  - quota fallback은 Z.ai code `1113`, `1308`, `1310`, `1316`–`1321`로 제한하고
    단기 rate limit·model 미지원·인증·worker protocol 오류와 분리.
- `git diff --check` → 통과.
- 설계 문서 커밋: `d383ba5` (`docs: design the GLM worker plugin routing`).

### spec 검토 반영 — connector MCP

- User 결정: Claude Code의 connector MCP를 사용하는 작업은 native Claude를
  우선한다.
- 근거: 설계된 `glm-agent:glm-worker` bridge의 tool surface는 `Bash, Read`이고,
  부모 Claude Code 세션의 MCP 도구·연결·인증 상태를 내부 GLM session에
  전달하는 계약이 없다.
- spec의 provider 선택 정책과 테스트 전략에 이 조건을 추가했다.
- 반영 커밋: `9524953` (`docs: route connector MCP work to Claude`).

### spec 검토 반영 — 역할별 agent와 explorer 권한

- 이전 결정의 `glm-agent:glm-worker` 단일 agent 설계는 이 결정으로 대체한다.
- custom agent를 `glm-agent:explorer`와 `glm-agent:general-purpose`로 나눈다.
  모델별 분리가 아니라 조사와 구현의 routing trigger를 분리하는 역할별 구조다.
- explorer는 코드베이스 탐색을 위해 내부 GLM session의 `Bash`, `Grep`, `Glob`,
  `Read` 등을 사용할 수 있다.
- User 결정: explorer에도 `--dangerously-skip-permissions`를 사용한다. 세밀한
  allowlist, permission mode, 별도 sandbox로 비수정을 강제하지 않는다.
- explorer의 비수정은 system prompt 행동 계약으로 두고, 오케스트레이터가 완료
  후 예상하지 않은 diff를 확인한다.
- CLI는 `role=explorer|general-purpose`를 worker meta에 저장하고 `send`에서
  원래 role을 유지한다. 공통 durable-result prompt와 role prompt는 별도 Markdown
  파일에서 매 turn 직접 읽는다.
- 반영 커밋: `db662d7` (`docs: split GLM workers by role`).

### spec 승인·계획 단계 진입

- User 지시: “superpowers를 이용해서 구현 시작”.
- 해석: 현재 spec을 승인하고 Superpowers 구현 절차로 전환한다.
- `superpowers:writing-plans`에 따라 제품 코드보다 먼저 implementation plan을
  작성한다. plan 검토 전에는 구현 파일을 변경하지 않는다.
