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
- 계획 문서 작성:
  `superpowers/plans/2026-09-28-glm-worker-plugin-routing.md` (875행, 6 tasks).
- plan self-review:
  - spec의 role persistence, prompt 직접 읽기, quota code 분류, marketplace/plugin,
    버전 parity, `my-superpowers`, connector/MCP native routing을 task에 매핑했다.
  - 서로 다른 cwd의 explorer·general-purpose worker를 동시에 시작하는 hermetic
    병렬 테스트를 Task 1에 포함했다.
  - worktree 실행 시 primary checkout을 잘못 검사하지 않도록 install smoke가
    `git rev-parse --show-toplevel`을 사용한다.
  - placeholder 금지 표현 검색 결과 없음. `git diff --check` 통과.
- 계획 커밋: `fb24969` (`docs: plan the GLM worker plugin implementation`).

### Native 구현 실행 준비

- User가 Native 실행을 승인했다. 별도 구현 subagent 없이 현재 세션에서 계획의
  Task 1~6을 연속 실행한다.
- 구현은 저장소 내부 `.worktrees/glm-worker-plugin`의 격리 worktree와
  `feat/glm-worker-plugin` 브랜치에서 진행한다. `.worktrees/`는 repository
  추적 대상에서 제외한다.
- Ruling: `superpowers:executing-plans`의 `.superpowers/sdd` helper workspace는
  User의 명시적인 repository-local `.superpowers` 금지와 충돌하므로 사용하지
  않는다. 대신 이 committed 작업 원장과 plan의 Task heading으로 동일한 진행
  상태와 검증 증거를 기록한다. 이 판단이 틀렸을 때의 비용은 helper가 생성하는
  brief/test-log 자동화가 없다는 것이며, 구현 결과물이나 검증 범위는 줄이지 않는다.
- 격리 worktree 생성 완료:
  `/Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-worker-plugin`, branch
  `feat/glm-worker-plugin`.
- 구현 전 기준선: `bash tests/test_glm_agent.sh` 91/91 통과,
  `bash -n glm-agent tests/test_glm_agent.sh` 통과, shellcheck 통과.

### Task 1 — 역할 인식 지속 worker

- RED: 기존 CLI에서 `role` metadata와 role prompt가 없고 `--role`이 unknown
  option으로 거부되는 것을 확인했다.
- GREEN: `explorer|general-purpose` 역할 검증·저장·출력, 매 turn의 별도 role
  prompt 직접 읽기, `send` 역할 유지, 서로 다른 cwd에서의 병렬 worker 생성을
  구현했다.
- 검증: `tests/test_glm_agent.sh` 109/109 통과, Bash 문법 검사와 shellcheck 통과.

### Task 2 — Z.ai 오류 분류

- RED: provider code가 있어도 기존 출력이 `ERROR=claude-exit-1`만 제공해 quota,
  transient, authentication, model unavailable을 구분하지 못함을 확인했다.
- GREEN: 공식 quota code만 `quota-exhausted`로 분류하고, 다른 알려진 code 및
  worker protocol 오류를 구분했다. 모든 turn 출력과 status에 `ERROR_KIND`,
  `PROVIDER_CODE`, `FALLBACK_RECOMMENDED`의 안정적인 필드 집합을 추가했다.
- 검증: `tests/test_glm_agent.sh` 215/215 통과, API key와 session ID 비노출,
  Bash 문법 검사와 shellcheck 통과.

### Task 3 — Claude Code marketplace와 역할별 agent

- Ruling: available `plugin-creator` skill은 Codex `.codex-plugin` 전용이므로
  Claude Code `.claude-plugin` schema 생성에는 적용하지 않았다. skill의 실제
  validator 우선 원칙을 유지하고 `claude plugin validate --strict`를 판정 기준으로
  사용했다. 잘못된 판단의 비용은 Codex용 marketplace 연동을 별도로 만들지 않은
  것이며, 이번 요청 범위인 Claude Code plugin에는 영향이 없다.
- RED: manifest와 역할 agent 4개가 없어 plugin test가 4건 실패했다.
- GREEN: marketplace/plugin manifest와 Haiku bridge인 `explorer`,
  `general-purpose` agent를 추가했다. 두 agent 모두 worktree를 소유하지 않고,
  persistent worker를 명시적 close 전까지 유지한다.
- 검증: `tests/test_plugin.sh` 10/10 통과(공백 포함 경로 포함),
  `claude plugin validate --strict .` 통과, Bash 문법 검사와 shellcheck 통과.

### Task 4 — 버전 동기화

- RED: 세 버전의 현재 parity는 확인됐지만 bump script가 없어 테스트 1건이
  실패했다.
- GREEN: 임시 파일 세 개를 모두 먼저 생성·검증한 뒤 교체하는 Bash 3.2 호환
  `scripts/bump-version.sh`를 추가했다. 잘못된 semver는 파일을 바꾸지 않는다.
- `AGENTS.md`에 plugin 구조, 전체 gate, synchronized release 절차를 추가했다.
- 검증: plugin test 20/20, script/test 문법 검사와 shellcheck, Claude strict
  validation 통과. 실제 checkout의 세 버전은 모두 `0.2.0`으로 유지됐다.

### Task 5 — 공개 문서와 my-superpowers provider routing

- RED: CLI help에 role/fallback 필드가 없고 README에 marketplace 설치, 역할별
  agent, connector/MCP routing이 없음을 테스트로 확인했다. 개인
  `my-superpowers`에도 GLM provider routing 키워드가 전혀 없었다.
- GREEN: help와 README에 plugin 설치, 두 역할, persistent lifecycle, 위험 권한,
  native 우선 조건, quota 전용 fallback을 문서화했다.
- 외부 수정: `/Users/h_kang/.claude/skills/my-superpowers/SKILL.md`의 §6에서
  `**띄우는 방법**` 바로 앞에 `### native Claude와 GLM provider 선택` 절을
  추가했다. explorer/general-purpose 선택, connector/MCP native 우선,
  bridge Haiku와 실제 `GLM_MODEL` 분리, `WORKER_ID` resume, quota latch와 같은
  논리 등급 native fallback을 명시했다. 기존 thin-main, ledger, tier, file-return,
  verification 규칙은 변경하지 않았다.
- Ruling: `superpowers:writing-skills`가 요구하는 fresh subagent pressure test는
  User가 선택한 Native 실행 및 별도 요청 없는 subagent 생성을 금지한 현재 실행
  규칙과 충돌해 수행하지 않았다. 정적 baseline 부재 확인, post-edit routing
  contract 검색, YAML frontmatter parsing으로 대체했다. 이 판단이 틀렸을 때의
  비용은 실제 agent가 압박 상황에서 routing을 따르는지에 대한 경험적 표본이
  없다는 것이다.
- 공식 `quick_validate.py`는 `ModuleNotFoundError: No module named 'yaml'`로
  실행되지 않았다. Ruby `YAML.safe_load`로 frontmatter의 `name`과 `description`
  유효성을 확인했다.
- 검증: CLI test 218/218, plugin test 25/25 통과. README, CLI help, 개인 skill에서
  `glm-agent:explorer`, `glm-agent:general-purpose`, `FALLBACK_RECOMMENDED`,
  `connector/MCP`의 의도한 위치를 확인했다.

### 최종 self-review 보완

- 승인 spec의 bridge 출력 계약과 구현을 대조해 start/send 출력의 `MODEL` 누락을
  발견했다. 또한 agent prompt가 지원 모델 세 개를 설명하지만 다른 값을
  명시적으로 거부하지 않는 누락을 발견했다.
- RED: CLI test 4건, plugin prompt test 2건이 새 계약에서 실패했다.
- GREEN: control-plane 출력에 저장된 `MODEL`을 추가하고 두 bridge 모두
  `opus|sonnet|haiku` 외 `GLM_MODEL`을 거부하도록 명시했다. README와 help 예시도
  동기화했다. test fixture checksum은 비필수 `shasum` 대신 POSIX `cksum`으로
  바꿨다.
- 검증: CLI test 220/220, plugin test 27/27, 관련 Bash 문법·shellcheck와 Claude
  strict validation 통과.

### Task 6 — 최종 검증 (2026-09-28 20:03 JST)

- committed HEAD 전체 gate:
  - `bash tests/test_glm_agent.sh` → 220/220 통과.
  - `bash tests/test_plugin.sh` → 27/27 통과.
  - `bash -n glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh`
    → 통과.
  - `shellcheck glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh`
    → 통과.
  - `claude plugin validate --strict .` → `✔ Validation passed`.
  - `git diff --check` → 통과, worktree clean.
- version parity: CLI/plugin/marketplace 모두 `0.2.0`.
- 격리 install smoke:
  - `CLAUDE_CONFIG_DIR=/tmp/glm-agent-plugin-smoke.BappcV/claude`.
  - local marketplace add 및 `glm-agent@glm-agent --scope user` 설치 성공.
  - inventory: Agents 2 (`explorer`, `general-purpose`), Skills/Hooks/MCP/LSP 0,
    version `0.2.0`.
- 실제 Z.ai persistence smoke:
  - 임시 repo `/tmp/glm-agent-live.9kHIu5`.
  - worker `20260928T105704Z-11018-26715`, role `explorer`, model `haiku`.
  - start turn 1 `DONE`, send turn 2 `DONE`, 두 turn 모두 fallback false.
  - status에서 session ID 비노출과 원래 cwd/role/model 유지 확인 후 explicit close;
    history는 `~/.glm/workers/20260928T105704Z-11018-26715`에 보존.
- GitHub 확인: `powdream-org/glm-agent`는 PUBLIC, default branch `main`, remote도
  `https://github.com/powdream-org/glm-agent.git`. `gh`에는 active
  `heejoon-toridori`와 inactive `powdream` 두 계정이 있으므로 push 시 요청대로
  `powdream` 계정을 명시적으로 선택해야 한다.
- 별도 subagent reviewer는 Native 실행 선택과 현재 subagent 생성 금지 규칙 때문에
  호출하지 않았다. 대신 승인 spec 각 절과 branch diff를 직접 대조했고, 그 과정에서
  `MODEL`/invalid model 계약 누락을 발견해 위의 self-review 보완 커밋으로 수정했다.

### main 공개 반영

- `feat/glm-worker-plugin`을 로컬 `main`에 `--ff-only`로 통합했다.
- 병합된 `main`에서 CLI 220/220, plugin 27/27, Bash 문법, shellcheck,
  `claude plugin validate --strict .`, `git diff --check`를 다시 실행해 모두 통과했다.
- `gh auth switch --user powdream` 후 `gh api user`가 `powdream`임을 확인하고
  `origin/main`에 push했다. 원격 HEAD는
  `b12e4ae961092555c0104a9e718a4bee11358015`로 로컬과 일치했다.
- push 후 active `gh` account는 기존 `heejoon-toridori`로 복원했다.
