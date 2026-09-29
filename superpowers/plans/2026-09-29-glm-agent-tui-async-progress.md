# SDD ledger — plan: superpowers/plans/2026-09-29-glm-agent-tui-async-implementation.md

- 착수: 2026-09-29
- 브랜치: `feat/tui-async-supervision`
- worktree: `/Users/h_kang/dev/git/powdream/glm-agent/.worktrees/tui-async-supervision`
- 기준: `origin/main` = `0c930b44074c37c05cfece4417e23791dbb5b950`
- 실행 방식: native (`superpowers:executing-plans`)

## 결정

- Ruling: 실행 scratch와 원장을 `<repo>/.superpowers/`에 만들지 않고 이 파일을 사용한다 — 사용자 범위 `my-superpowers`가 대상 repo의 `.superpowers/`를 금지하고 이 repo의 `superpowers/plans/*-progress.md`를 지정한다 — 잘못되면 executing-plans 보조 script를 그대로 쓸 수 없어 task brief와 완료 기록을 수동으로 유지해야 한다.
- Ruling: custom-agent Markdown은 static destination assertion과 `claude plugin validate`로 계약을 고정하고 실제 routing은 release smoke test로 검증한다 — Markdown interpreter를 hermetic하게 실행할 local unit boundary가 없고 source assertion만으로 semantic 실행을 증명할 수 없다 — 잘못되면 문구는 맞지만 실제 agent가 명령을 잘못 실행하는 결함을 smoke 단계까지 발견하지 못한다.

## Pre-flight interface 점검

- Task 1 → Task 2: `prepare_turn`, `execute_headless_turn`, worker lock을 async runner가 소비한다. 이름과 상태 경계가 일치한다.
- Task 2 → Task 3: runner PID와 active lock을 cancel이 소비한다. `provider_pgid` 필드는 Task 1에서 schema를 만들고 Task 3 runner가 채운다.
- Task 1/2 → Task 4: worker 생성, prompt 조합, lock을 TUI가 공유한다. TUI 전용 artifact만 별도다.
- Task 2/3 → Task 5: public async/wait/cancel CLI를 bridge ACTION이 그대로 소비한다.
- Task 1-5 → Task 6: 실제 command/control fields를 help·README·version gate가 문서화한다.
- Task 6 → Task 7: 검증된 0.4.0 commit을 review·push·installed plugin update가 소비한다.

## 진행

- Task 1: Ruling: `acquire_worker_lock DIR MODE TURN` 대신 `acquire_worker_lock DIR MODE`로 lock을 먼저 얻고 그 안에서 다음 turn을 계산·기록한다 — lock 전에 turn을 계산하면 두 호출이 같은 번호를 볼 수 있다 — 잘못되면 내부 호출부가 세 번째 인자를 기대하는 불일치가 생기지만 public interface 영향은 없다.
- Task 1: RED — `bash tests/test_glm_agent.sh` → 229개 중 5개 실패: exit-zero quota 응답 3개가 `worker-protocol`, 겹친 send 2개가 성공/무오류.
- Task 1: complete — `bash -n glm-agent tests/test_glm_agent.sh && bash tests/test_glm_agent.sh` → 229/229 pass.
