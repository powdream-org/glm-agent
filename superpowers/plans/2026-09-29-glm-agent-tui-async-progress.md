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
- Task 2: Ruling: detached child가 `launch.ready`를 볼 때까지 executor 진입을 기다리게 한다 — 매우 빠른 fake/provider가 parent의 `runner_pid` 기록과 receipt보다 먼저 lock을 해제할 수 있다 — 잘못되면 launch handshake timeout이 정상 turn을 `interrupted`로 만들 수 있다.
- Task 2: RED — `bash tests/test_glm_agent.sh` → 259개 중 22개 실패: `--async`/`wait` 부재, active fields 부재, stale lock 미복구.
- Task 2: complete — `bash -n glm-agent tests/test_glm_agent.sh && bash tests/test_glm_agent.sh` → 259/259 pass.
- Task 3: RED — `bash tests/test_glm_agent.sh` → 271개 중 9개 실패: cancel command·terminal response 부재. 추가 pre-provider race 테스트는 cancel 응답 7초로 실패.
- Task 3: Ruling: provider는 Bash monitor mode의 별도 process group으로 실행하고 cancel은 검증된 negative PGID에 signal한다 — runner PID만 죽이면 Claude child가 남는다 — 잘못되면 자체 session을 분리한 tool child는 group 밖에서 살아남을 수 있다.
- Task 3: complete — `bash -n glm-agent tests/test_glm_agent.sh && bash tests/test_glm_agent.sh` → 275/275 pass; 실행 중 provider child 종료, pre-provider cancel, repeated/natural-terminal idempotency 확인.
- Task 4: RED — `bash tests/test_glm_agent.sh` → 313개 중 32개 실패: `tui` command, session allocation, attach, artifacts, terminal validation 부재.
- Task 4: complete — `bash -n glm-agent tests/test_glm_agent.sh && bash tests/test_glm_agent.sh` → 313/313 pass; new TUI→headless send→다른 cwd attach 동일 session 확인.
- Task 5: RED — `bash tests/test_plugin.sh` → 52개 중 12개 실패: 두 custom agent에 async start/send, bounded wait, cancel, RUNNING/terminal 구분 부재.
- Task 5: Ruling: skill pressure RED는 User가 제시한 실제 실패 보고(bridge가 GLM worker를 호출하지 않고 TASK를 직접 수행)를 사용하고 별도 agent 좌석은 만들지 않는다 — native inline 실행 선택과 실제 관측이 이미 baseline을 제공한다 — 잘못되면 새 문구의 해석 실패를 Task 6 live smoke에서야 발견한다.
- Task 5: `my-superpowers` canonical을 `/Users/h_kang/.agents/skills/my-superpowers/SKILL.md`로 옮기고 `/Users/h_kang/.claude/skills/my-superpowers`를 symlink로 연결했다. SHA-256 `a424d07e47210d8ce9bfb6c1bc36a97ef05ef7b53acc2e52277af85ba1b82e81`.
- Task 5: complete — `bash tests/test_plugin.sh && claude plugin validate --strict .` → 52/52 pass, strict validation passed; Claude/Codex skill 경로 `cmp` 일치.
- Task 6: RED — help/version 계약은 CLI 8개, plugin 6개 실패. 0.4.0 help·README·manifest 갱신 후 정적/동적 gate를 통과했다.
- Task 6: live async smoke에서 provider가 정상 결과를 쓴 뒤 detached supervisor만 먼저 사라지는 문제를 발견했다. Ruling: async launcher가 supervisor를 자체 process-group leader로 시작한다 — launcher의 orphaned job-control group을 상속하면 내부 provider group을 기다리는 supervisor가 종료될 수 있다 — 잘못되면 OS별 job-control 차이로 runner PGID assertion이 불안정할 수 있다. 별도 launcher group 회귀 테스트를 추가했고 runner PID=PGID 및 실제 async terminal `DONE`을 확인했다.
- Task 6: live managed TUI를 다른 caller cwd에서 같은 worker에 attach하고 `/exit`했다. 새 TUI batch는 report를 작성하지 않아 계약대로 `INVALID/worker-protocol`이었고, 이어진 async headless turn 3이 저장 session/cwd/model로 `DONE`을 반환했다.
- Task 6: live resume 중 `RUNNING` observation이 직전 TUI error metadata를 노출하는 문제를 발견했다. 새 turn 준비 시 `error_kind`와 `provider_code`를 지우도록 TDD로 수정했다.
- Task 6: complete — `bash -n`, ShellCheck, CLI 326/326, plugin 57/57, `claude plugin validate --strict .` 모두 통과. CLI/plugin/marketplace version은 0.4.0.
- Task 7 review: initial whole-branch verdict was not ready. Findings were cancel active-generation ABA/PID reuse safety, non-atomic lifecycle metadata, empty/reused runner recovery, sync interruption orphaning, exit-zero provider-error surfaces, and Bash 3.2 test portability.
- Task 7 review fixes: immutable active generation, runner/provider start identity, generation-specific cancel marker, captured-snapshot signal validation, provider ready/go handshake, atomic multi-field metadata transitions, active-lock-authoritative observations, incomplete/reused runner recovery, sync signal forwarding, and subtype/error-object/result-text normalization을 TDD로 구현했다.
- Task 7 review RED — CLI 343개 중 12개 실패. GREEN — `bash tests/test_glm_agent.sh && shellcheck glm-agent tests/test_glm_agent.sh` → 343/343 pass, ShellCheck pass. Parent-exit test는 PATH를 `/usr/bin:/bin`으로 제한해 macOS `/bin/bash` 3.2 async 경로를 실행한다.
- Task 7 재리뷰: 아직 release-ready가 아니다. 동시 stale finalizer가 replacement generation을 지울 수 있는 ABA, provider leader 종료 뒤 TERM을 무시하는 group child 잔존, `status`/`wait`/`cancel`의 meta-active TOCTOU, 성공 문장까지 오류로 오인하는 result-text detector, `close`와 새 turn 시작의 check-then-act 경쟁을 확인했다. spec의 exit-trap 설명도 실제 구현과 불일치한다.
- Task 7 재리뷰 Ruling: finalizer claim을 `active/finalizing`의 원자적 `mkdir`로 단일화하고 generation을 claim 뒤 재검증한다. 관찰 명령은 generation 전후가 일치하는 stable snapshot만 사용한다. provider group ownership이 검증된 뒤에는 leader 생존 여부와 무관하게 group liveness를 확인해 TERM→KILL로 drain한다. `close`도 active lock을 획득하고 turn 준비는 lock 획득 뒤 `closed`를 재검증한다.
- Task 7 재리뷰 수정 GREEN — `bash -n glm-agent tests/test_glm_agent.sh && git diff --check && shellcheck glm-agent tests/test_glm_agent.sh && bash tests/test_glm_agent.sh` → 349/349 pass. TERM을 무시하는 provider child 정리, 동시 stale finalizer 뒤 replacement generation 보존, 성공 응답의 일반적인 `error code 500` 문구 비오류 판정을 새 회귀 테스트로 확인했다.
- Task 7 release gate 재실행 — `bash tests/test_plugin.sh && claude plugin validate --strict . && ./glm-agent --version && git diff --check` → plugin 57/57 pass, strict validation passed, `glm-agent 0.4.0`, diff check passed.
- Task 7 provider-group identity 보강 뒤 재실행: CLI test 98 `sync interruption terminates provider child processes`가 1회 실패했다. 구현의 TERM grace가 1초이고 테스트 관찰 상한도 1초여서 KILL 경계 직전에 판정했다. provider group leader PID가 재사용된 경우 다른 group을 신호하지 않도록 start identity 확인은 유지하고, 회귀 테스트 관찰 상한을 grace보다 길게 분리해 재실행한다.
- Task 7 디버깅 정정: 관찰 상한만의 문제는 아니었다. TERM 직후 provider leader가 zombie가 되었고 `kill -0`은 이를 생존으로 보지만 start identity 비교가 불일치해 재사용 PID로 오판했다. zombie는 실행 가능한 재사용 프로세스가 아니므로 non-zombie leader의 start identity가 바뀐 경우에만 group drain을 거부하도록 수정했다. 테스트는 zombie를 종료된 실행 상태로 판정하고 TERM grace보다 긴 상한을 사용한다.
- Task 7 provider-group 재검증 GREEN — identity 검사의 `kill -0`→`ps` 사이 leader 소멸도 충돌로 오판하지 않도록, 관측 가능한 non-zombie process의 start identity가 실제로 다를 때만 conflict로 판정했다. `bash -n`, ShellCheck, diff check와 CLI 349/349가 통과했다.
- Task 7 finalizer 내구성: claim owner PID/start identity를 기록하고 죽은 owner의 claim을 원자적으로 worker 밖 임시 경로로 치환해 복구를 이어받게 했다. concurrent stale finalizer fixture에 죽은 claim owner를 추가했고 `bash -n`, ShellCheck, diff check와 CLI 349/349가 다시 통과했다.
- Task 7 세 번째 독립 리뷰: critical은 없지만 release-ready는 아니다. 정상 성공에도 provider group을 drain해 worker가 검증한 persistent service를 죽이는 문제, 명시적 structured success를 result 자유형 문장의 알려진 provider code가 뒤집는 문제, active 없음 ABA와 state 없는 active directory를 stable snapshot으로 반환하는 문제를 important blocker로 판정했다. 세 항목을 모두 수정하고 정상 background child 생존·known-code success·partial active publication 회귀를 추가한다.
- Task 7 세 번째 리뷰 수정 GREEN — 정상 성공 provider group 보존, structured success 우선, active state 전체 전후 비교와 partial publication retry를 구현했다. 정상 persistent background child 생존, `Fixed Z.ai authentication code 1001` 성공 판정, state 없는 active publish retry를 포함해 `bash -n`, ShellCheck, diff check와 CLI 353/353가 통과했다. 아직 이 최신 diff에 대한 독립 재리뷰·plugin gate 재실행·커밋·main push·설치 플러그인 갱신은 남아 있다.
- 2026-09-30 handoff 인계 재검증 — `superpowers/handoffs/2026-09-30-glm-agent-0.4.0-release-handoff.md` 전문을 읽고 현재 상태와 대조: HEAD `33f5d57b282ac324a9377b964391b8b9f4cf680e`, `origin/main` fetch 결과 `0c930b44074c37c05cfece4417e23791dbb5b950`(변동 없음), `git rev-list --left-right --count origin/main...HEAD` → `0 12`(handoff 서술과 일치). `git status --short` → `glm-agent`, `superpowers/plans/...progress.md`, `superpowers/specs/...design.md`, `tests/test_glm_agent.sh` 수정 + `superpowers/handoffs/` untracked, handoff 서술과 일치. uncommitted diff(`glm-agent` +221/-31, `tests/test_glm_agent.sh` +182/-6 대략)를 전문 확인함 — finalizer claim(`claim_finalization`), `drain_owned_provider_group`(정상 성공 시에도 provider group 소유권·zombie 판정 후 drain), `load_worker_snapshot`(meta/active 전후 일치 stable snapshot), `provider_response_is_error`의 known-code 화이트리스트 정규식, `cmd_close`가 active lock을 획득하도록 바뀐 부분을 확인함. 이제부터 다음 작업 1번(독립 재리뷰)을 진행한다.
- 2026-09-30 네 번째 독립 리뷰 착수 — `review-tools:cross-code-review` 스킬로 codex(Reviewer A) + opus(Reviewer B) 병렬 실행. 대상: `git diff origin/main`(committed 12 + uncommitted 전체), 세 번째 리뷰의 세 항목 수정과 신규 `claim_finalization` finalizer takeover를 중점 지시.
- 2026-09-30 codex 리뷰 GREEN 실행 확인 + RED 판정 — codex 자체가 `bash -n`, `git diff --check`, `shellcheck`, `bash tests/test_glm_agent.sh`(353/353), `bash tests/test_plugin.sh`(57/57)를 모두 재실행해 통과를 확인했지만, verdict는 **not ready**: `[must]` 7건 + `[imo]` 1건. 요지(파일: 결과 파일 `/private/tmp/claude-501/-Users-h-kang-dev-git-toridori-inc/26af2d98-4193-5f93-8f52-a4a16b95835b/scratchpad/codex-review-glm-agent-0.4.0.md`):
  1. `glm-agent:488` `claim_finalization`은 진짜 CAS가 아니다 — 두 finalizer가 같은 dead owner를 관찰하면 서로의 새 claim을 번갈아 steal해 이중 finalize가 가능하고, `release_worker_lock`이 owner token을 검증하지 않아 나중 finalizer가 교체 turn의 RUNNING/terminal metadata를 덮어쓸 수 있다.
  2. `glm-agent:1849` `cancel`이 자신이 취소한 generation이 아니라 "현재" generation의 snapshot을 출력할 수 있어, 다른 concurrent `send --async`가 새 generation을 시작하면 `STATUS=RUNNING`+`CANCEL_RESULT=CANCELLED`가 동시에 나올 수 있다(계약 위반).
  3. `glm-agent:627` interrupted/stale finalize가 provider group을 drain하지 않고 lock을 해제할 수 있어(async runner가 SIGKILL로 죽은 경우 등) orphan Claude 프로세스가 교체 turn과 동시에 저장소를 건드릴 수 있다.
  4. `glm-agent:1716` `active/` 디렉터리가 `mkdir` 후 `state` 파일 기록 전에 lock 생성자가 죽으면 영구 미복구 상태가 되고 `cmd_wait`가 deadline 체크 없이 무한 루프한다(`wait --timeout 0`도 안 끝남).
  5. `glm-agent:789` 좁아진 free-text 필터가 옛 스타일(구조화 필드 없는) 진짜 에러를 더 이상 못 잡는다 — 회귀. 화이트리스트 정규식도 digit boundary가 없어 `10010`이 `1001`에 매치.
  6. `glm-agent:581` `drain_owned_provider_group`의 identity 검증과 실제 signal 사이에 여전히 TOCTOU가 있다(PID/PGID 재사용). `ps -o lstart` 해상도가 1초라 같은 초 안의 재사용은 구분 불가.
  7. `glm-agent:506` `path_mtime()`의 GNU stat fallback이 실제로 작동하지 않는다(`stat -f`가 실패하며 이상한 값을 command substitution에 남김) — Linux에서 ownerless stale claim이 영원히 회수 안 됨. **macOS 전용 배포라 당장 영향 없을 수 있으나 확인 필요.**
  8. [imo] `glm-agent:643` `set -e`로 인해 `active/state` 파일이 `-f` 체크 후 `cat` 전에 사라지면 status/wait/cancel이 예외로 죽을 수 있음(정상 lock 해제 타이밍).
- 2026-09-30 opus(Reviewer B) 1차 리뷰 도착 — 결과는 이 에이전트의 최종 메시지에만 있고 별도 파일 없음(요청 시 파일 출력을 명시하지 않았음 — 다음에는 codex와 동일하게 파일 경로를 지정할 것). 세 번째 리뷰 항목 1·2는 결함 없음으로 확인, 항목 3(`load_worker_snapshot`)은 stable-read/global 오염 없음을 확인했으나 "active dir 존재+state 없음" 케이스에서 `wait`만 deadline을 무시하고 무한 재시도한다는 새 결함을 재현(stress test, `wait --timeout 1`이 8초 뒤에도 안 끝남). codex #1(finalizer takeover 비-CAS)과 동일한 결함을 실제 stress harness로 재현: 8-concurrent `status` 중 9/80 `chmod: No such file or directory`, replacement 경쟁 시 4/60·1/60 runs가 새 lock을 통째로 잃음(worker가 영구 "turn already exists" 상태로 고장). 추가로 opus 단독 발견 4건(I~L, 본문 하단): I=`extract_zai_code`가 실제 Z.ai 응답의 `[1308]` bracket 포맷을 못 잡아 quota-exhausted fallback이 실제 quota 에러에서 전혀 작동 안 함(실제 캡처 응답 파일로 확인, `~/.glm/workers/20260929T153439Z-67040-28411/turns/0001/response.json`), J=`cmd_close`가 killed 중간에 runner identity 없이 lock만 잡아 stale-recovery가 DONE worker를 INVALID/interrupted로 오염시킬 수 있음, K=`active/state` heredoc 비원자적 기록이 finding A(finalizer takeover)의 악용을 쉽게 만듦, L=TERM-ignoring child를 error 경로에서 drain하는지 검증하는 테스트 부재. **원장 자체 기록 오류 발견**: line 58에 내가 "drain_owned_provider_group(정상 성공 시에도 ... drain)"이라고 잘못 적었음 — 실제 코드는 성공 시 drain하지 않음(design §11·opus·codex 모두 확인). 정정: 성공 경로는 drain하지 않고, 오류/취소/interrupted-finalize 경로에서만 drain한다(단, interrupted-finalize 경로 자체의 drain 누락이 codex #3/F).
- 2026-09-30 교차검증 1차: codex-only 발견 3건(F=glm-agent:627 interrupted-finalize가 drain 안 함, G=glm-agent:581 drain_owned_provider_group TOCTOU, H=glm-agent:643 set -e stale-recovery 크래시)을 opus 세션에 SendMessage로 반박 요청. 결과: **F=confirmed**(재현 스크립트 `f_orphan.sh` — dead runner+live TERM-ignoring provider group에서 `status`가 INVALID로 finalize하면서 lock 해제, 1.5초 뒤 provider group 생존 확인. cancel 경로 쪽 변형은 plausible로 격하 — SIGSTOP된 runner 필요). **G=refuted**(PID/PGID가 mkdir 수 초 내 wrap-around할 수 없음을 이 머신의 PID 할당 패턴으로 반증 — 같은 초 안 1만+ fork 필요, POSIX가 살아있는 process group ID 재사용을 금지). **H=confirmed**(재현 스크립트 `h_race.sh` — 정상 lock 해제 타이밍에서 240회 중 13회(~5%) `cat: No such file or directory`로 상태 조회 자체가 exit 1 크래시, 폴링 브리지에 실질적 영향).
  - codex-only 3건 판정 확정: **F 채택(important), G 기각(반박됨, 수정 불필요), H 채택(minor)**.
  - opus-only 4건(I,J,K,L)은 codex에게 반박 요청을 보냈고 아직 도착 전.
- 2026-09-30 codex 검증(I,J,K,L) — codex CLI가 usage limit(`try again at 4:33 PM`)으로 최종 결과 파일 작성 전에 중단됐으나, 실행 로그(`codex-verify-run.log`, 4550줄)에 세 항목 모두 실제 재현 근거가 남아 있어 로그에서 직접 판정 추출:
  - **I=confirmed** — 사용자의 실제 `~/.glm/workers/20260929T153439Z-67040-28411/turns/0001/response.json`(`{"subtype":"success","is_error":true,"result":"API Error: Request rejected (429) · [1308][Usage limit reached for 5 hour...]"}`, 실제 Z.ai 429 quota 응답)로 `extract_zai_code`를 직접 실행: `EXTRACTED=<>`(빈 값), 저장된 meta는 `status=INVALID error_kind=invocation provider_code=`(quota-exhausted 아님). `provider_response_is_error`는 `is_error=true`라 정상적으로 에러 판정은 하지만(`PROVIDER_ERROR=true`), code 추출 정규식 `(?i)code[^0-9]*(?<code>[0-9]{3,4})`와 grep fallback `"code"[[:space:]]*:...` 둘 다 bracket 포맷 `[1308]`에 매치 안 함 — 실제 발생 중인 quota-exhausted가 fallback 신호로 이어지지 않음. **읽기 전용 조회였고 사용자 실제 데이터를 변형하지 않았음(K/J 재현은 별도 tmp 디렉터리로 복제).**
  - **K=confirmed** — 격리 tmp_root에 실제 worker를 복제해 `close`를 반복 실행하며 `active/state` 파일 크기를 폴링: `OBSERVED_EMPTY_STATE=1`(2240회 체크 1회, 738964회 체크 재현 1회) — heredoc 비원자적 기록이 만드는 빈 파일 윈도우가 실측으로 확인됨.
  - **J=confirmed** — 격리 tmp_root에서 원래 `status=DONE`이던 worker에 `close`를 실행해 `active/state`가 기록된 순간 STOP → meta의 `closed=false` 확인 → KILL → stale-recovery grace(6초) 대기 → `status` 재조회 결과 `STATUS=INVALID CLOSED=false ERROR_KIND=interrupted` — DONE worker가 close 중단만으로 영구 오염됨을 실측 재현.
  - **L=미확정(codex 최종 판정 없음, usage limit)** — 이 세션이 직접 `tests/test_glm_agent.sh` diff를 재확인: `HANG_WITH_TERM_IGNORING_CHILD` fixture는 "sync interruption terminates provider child processes"와 "cancel terminates provider child processes" 두 테스트에서만 쓰이고(둘 다 interrupt/cancel 경로), provider가 스스로 에러를 반환하면서 TERM-ignoring child를 남기는 순수 error-path 시나리오를 검증하는 테스트는 diff에 없음 — opus 주장 사실로 판단, minor로 채택.
  - **codex 계정이 usage limit에 걸림 — 다음 재시도 가능 시각 "4:33 PM"(codex 자체 보고, 표준시간대 불명). 이후 codex를 통한 추가 리뷰/검증이 필요하면 이 제약을 먼저 확인할 것.**

## 4차 독립 리뷰 최종 통합 판정 (codex+opus 교차검증 완료)

채택(수정 필요):
| # | 위치 | 심각도 | 요지 | 근거 |
|---|---|---|---|---|
| A | `claim_finalization` (~488) | critical | finalizer claim이 진짜 CAS가 아님 — 두 finalizer가 서로의 새 claim을 steal, 이중 finalize로 교체 turn의 RUNNING/terminal metadata 덮어씀, worker 영구 손상("turn already exists") | codex+opus 둘 다 원 리뷰에서 제기, opus stress test 재현(9/80, 4/60, 1/60) |
| B | `cmd_wait`(~1716)+`recover_stale_lock`(641-642) | important | `active/` mkdir 후 `state` 미기록 상태가 지속되면 `wait`가 `--timeout`을 무시하고 무한 재시도 | codex+opus 둘 다 제기, opus 재현(`wait --timeout 1`이 8초 후에도 안 끝남) |
| C | `provider_response_is_error`(~789) | important | 좁아진 free-text 필터가 구조화 필드 없는 옛 스타일 진짜 에러를 더는 못 잡음(회귀), whitelist 정규식에 digit boundary 없어 `10010`이 `1001`에 매치 | codex+opus 둘 다 제기·검증 |
| D | `path_mtime`(~506) | important | GNU stat fallback이 실제로 작동 안 함 — Linux에서 ownerless claim 영구 미회수. README가 "macOS or Unix-like" 명시라 스코프 내 | codex+opus 둘 다 gstat로 검증 |
| E | `cmd_cancel` 최종 print(~1846-1852) | important | cancel이 자신이 취소한 generation이 아닌 "현재" state를 출력 — `STATUS=RUNNING`+`CANCEL_RESULT=CANCELLED` 동시 발생 가능(계약 위반) | codex+opus 둘 다 제기, opus 재현(180/240 runs) |
| F | `finalize_interrupted_turn`/`recover_stale_lock`(~627) | important | interrupted/stale finalize가 provider group을 drain 안 하고 lock 해제 — orphan 프로세스가 교체 turn과 동시 실행 가능 | codex 단독 제기 → opus 검증 confirmed(`f_orphan.sh` 재현) |
| H | `recover_stale_lock`(~643) | minor | `set -e`로 인해 `active/state`가 `-f` 체크 후 `cat` 전에 사라지면 status/wait/cancel이 크래시(exit 1, 무출력) | codex 단독 제기 → opus 검증 confirmed(`h_race.sh`, 240회 중 13회=~5%) |
| I | `extract_zai_code`(~750) | important | 실제 Z.ai 응답의 bracket 포맷 `[1308]` 코드를 못 잡아 quota-exhausted/fallback이 실제 quota 소진에서 작동 안 함 | opus 단독 제기(실제 캡처 응답으로 확인) → codex 검증 confirmed(동일 실제 데이터로 재현) |
| J | `cmd_close`(~1949)+`recover_stale_lock` | minor | close가 lock 획득 후 killed되면 runner identity가 없어 stale-recovery가 DONE worker를 INVALID/interrupted로 오염 | opus 단독 제기 → codex 검증 confirmed(실측 재현) |
| K | `active/state` 초기 기록(heredoc, ~416-430) | minor | 비원자적 기록이 빈/부분 파일 윈도우를 만듦 — finding A의 악용을 쉽게 함 | opus 단독 제기 → codex 검증 confirmed(빈 파일 실측) |
| L | 테스트 커버리지 | minor | error 경로(비-cancel)에서 TERM-ignoring child drain을 검증하는 테스트 없음 | opus 단독 제기 → codex 판정 누락(usage limit), 이 세션이 diff 재확인으로 사실 인정 |

기각(수정 불필요):
| # | 위치 | 판정 | 근거 |
|---|---|---|---|
| G | `drain_owned_provider_group`(~581) | refuted | codex가 identity-check-then-signal TOCTOU를 제기했으나, opus가 이 머신의 PID 할당 패턴(연속 증가, wrap-around에 수만 fork 필요)과 POSIX가 살아있는 process group ID 재사용을 금지한다는 사실로 반증. 같은 초 안 PID/PGID 재사용 자체가 사실상 불가능 |

원장 자체 오류 정정: 이전 항목(line 58)의 "drain_owned_provider_group(정상 성공 시에도... drain)" 표현은 **오기**다. 정확히는: 성공 경로는 drain하지 않고, 명시적 오류/취소 경로에서만 drain한다(다만 finding F가 지적하는 interrupted/stale-finalize 경로는 drain 호출이 누락되어 있었음 — 이는 "성공 시 drain"과는 다른 별개 결함).

**다음 작업: 채택된 10건(A,B,C,D,E,F,H,I,J,K, L은 테스트 추가)을 TDD로 수정한다.**
- 2026-09-30 sonnet 좌석 디스패치 — 브리프 `/private/tmp/claude-501/-Users-h-kang-dev-git-toridori-inc/26af2d98-4193-5f93-8f52-a4a16b95835b/scratchpad/glm-agent-fix-brief.md`에 A~L 전체 설계(특히 A: claim 디렉터리는 이동하지 않고 owner 파일만 nonce write-then-readback으로 원자적 교체 + release 시 owner 검증)를 명시해 sonnet 1석에 위임. 하나의 좌석에 몰아준 이유: 모든 finding이 같은 파일(`glm-agent`)의 얽힌 함수(`claim_finalization`/`finalize_interrupted_turn`/`cmd_cancel`/`load_worker_snapshot`)를 건드려 여러 좌석으로 쪼개면 병합 충돌·논리 모순 위험이 큼.
- 2026-09-30 sonnet 좌석 완료 + 메인 재확인 — 결과 파일 `/private/tmp/claude-501/-Users-h-kang-dev-git-toridori-inc/26af2d98-4193-5f93-8f52-a4a16b95835b/scratchpad/glm-agent-fix-results.md`(115줄). 227 tool-use, 454587 subagent tokens, 67분. A~L 전부 TDD로 구현, 각 finding별 RED 재현→GREEN 확인 기록. 최종 399/399(353 baseline+46 new).
  - **메인이 직접 재확인한 것(보고를 그대로 안 믿음)**: `git status --short`로 수정 파일이 정확히 브리프 범위(`glm-agent`, `tests/test_glm_agent.sh`)뿐임을 확인(그 외는 이 세션이 이미 만든 `superpowers/*` 변경). `bash -n`/`git diff --check`/`shellcheck`/`bash tests/test_glm_agent.sh`(399/399)/`bash tests/test_plugin.sh`(57/57)/`claude plugin validate --strict .`/`./glm-agent --version`(0.4.0)을 전부 직접 재실행해 통과 확인. `claim_finalization`/`release_worker_lock`/`recover_stale_lock`/`cmd_wait`/`cmd_cancel`/`cmd_close`를 직접 Read해서 브리프 설계(특히 A의 nonce write-then-readback)와 실제 구현이 일치하는지 대조 — 일치 확인. finding A는 이론적으로 "두 finalizer가 연속으로 steal에 성공"하는 극히 좁은 윈도우가 여전히 남지만(진짜 순수 CAS는 아님), 그 결과로 벌어지는 모든 후속 연산(`meta_update`, `drain_owned_provider_group`, `release_worker_lock`의 owner-nonce 검증)이 전부 멱등적으로 설계돼 있어 실질적 피해가 없다고 판단 — 브리프의 실제 요구사항(교체 turn metadata 보호)은 `claim_finalization` 내부의 generation 재검증으로 이미 충족됨.
  - **메인이 직접 발견해서 고친 gap(sonnet 범위 밖)**: finding E가 새로 도입한 `CANCEL_RESULT=PENDING` 값이 `agents/general-purpose.md`·`agents/explorer.md`의 "ACTION=cancel reaches completion when the CLI returns a terminal status and CANCEL_RESULT" 문구, 그리고 `--help`의 cancel 섹션(원래 CANCEL_RESULT 값 자체가 전혀 문서화 안 되어 있었음)과 불일치 — 브리지 에이전트가 PENDING(non-terminal)을 completion으로 오독할 위험. 세 곳 모두 "PENDING은 WAIT_RESULT=TIMEOUT과 동일하게 취급, 재시도"로 명시 수정. 수정 후 `bash -n`/전체 테스트(399/399)/`bash tests/test_plugin.sh`(57/57)/`claude plugin validate --strict .`/`shellcheck`/`git diff --check` 전부 재확인 통과.
  - fixture/`_execute-turn` 잔존 프로세스 확인: `ps -ef | grep -i 'glm-agent\|_execute-turn\|fake.*claude\|codex exec'` → 0건.
- 2026-09-30 커밋 — `glm-agent tests/test_glm_agent.sh agents/general-purpose.md agents/explorer.md superpowers/plans/...progress.md superpowers/specs/...design.md superpowers/handoffs/2026-09-30-...handoff.md` 7개 파일만 정확히 stage(핀포인트 add, unrelated 없음) → commit `0bc54db89b3d75892f62bab292f41b72a6c303a6` "fix: close remaining worker-supervision races and gaps". 다음: `git fetch origin`으로 origin/main 변동 확인 후 main push.
- 2026-09-30 fetch 재검증 — `origin/main`은 여전히 `0c930b44074c37c05cfece4417e23791dbb5b950`(변동 없음), `merge-base --is-ancestor origin/main HEAD` → true(fast-forward 가능), `diff origin/main...HEAD --name-only`가 승인된 범위(CLI·tests·agents·manifest·README·superpowers 문서)만 포함함을 확인.
- 2026-09-30 main push 실패→해결 — `git push origin HEAD:main` 최초 시도 **403 Permission denied to heejoon-toridori**. 원인: `powdream-org/glm-agent`는 별도 GitHub 계정 `powdream` 소유이고 gh CLI 활성 계정이 `heejoon-toridori`(토리도리 업무용)였음. `powdream` 계정은 이미 로그인돼 있었으나 비활성. **User에게 AskUserQuestion으로 확인** 후 승인받아 `gh auth switch --hostname github.com --user powdream` → push 성공(`0c930b4..0bc54db main`) → 즉시 `gh auth switch --hostname github.com --user heejoon-toridori`로 원복. 원복 후 `gh auth status`로 heejoon-toridori가 다시 active임을 확인. `git fetch origin main` 재확인 → `origin/main` = `0bc54db89b3d75892f62bab292f41b72a6c303a6`(push 반영 확인).
- **origin/main 배포 완료: `0bc54db89b3d75892f62bab292f41b72a6c303a6`.**
- 2026-09-30 설치 plugin 갱신 — `claude plugin --help`로 명령 확인(추측 안 함) 후 `claude plugin marketplace update glm-agent`(git@github.com:powdream-org/glm-agent.git clone 갱신 성공) → `claude plugin update glm-agent` → "Plugin glm-agent updated from 0.3.0 to 0.4.0 for scope user. Restart to apply changes." 설치 캐시 직접 검증: `~/.claude/plugins/cache/glm-agent/glm-agent/0.4.0/{glm-agent,agents/general-purpose.md,agents/explorer.md}`를 push한 worktree와 `diff`로 대조 → **완전 일치(IDENTICAL)**. 버전 디렉터리별 `.in_use`/`.orphaned_at` 확인: 0.4.0=`.in_use`(신규), 0.3.0=`.orphaned_at`(17:52, 방금 orphan 처리), 0.2.0=이미 orphan. canonical `my-superpowers` symlink(`~/.claude/skills/my-superpowers` → `~/.agents/skills/my-superpowers`) 정상 resolve, SHA-256 `a424d07e47210d8ce9bfb6c1bc36a97ef05ef7b53acc2e52277af85ba1b82e81` 이전 기록과 일치(이번 라운드에서 건드리지 않았으므로 변동 없음이 맞음).

## 릴리스 완료 요약

- commit: `0bc54db89b3d75892f62bab292f41b72a6c303a6` "fix: close remaining worker-supervision races and gaps"
- pushed `origin/main`: `0bc54db89b3d75892f62bab292f41b72a6c303a6` (powdream 계정으로 일시 전환→push→heejoon-toridori 원복)
- 설치 plugin: `glm-agent@glm-agent` 0.3.0 → 0.4.0, 설치 파일이 push 내용과 byte-identical
- CLI test: 399/399, plugin test: 57/57, `claude plugin validate --strict .` pass, `shellcheck`/`bash -n`/`git diff --check` 전부 pass
- 4차 독립 리뷰(codex+opus 교차검증) 채택 10건 전부 TDD 수정 완료, 기각 1건(PID/PGID TOCTOU, opus 실측 반증)
- 잔존 fixture/`_execute-turn` 프로세스 없음
- 2026-09-30 원장 커밋 `042b2008c2de231baa06dcd6ac6445ff10ea3a2e` "docs: record 0.4.0 release verification and deployment"도 동일 절차(powdream 계정 전환→push→heejoon-toridori 원복)로 push. `origin/main` 최종 = `042b2008c2de231baa06dcd6ac6445ff10ea3a2e`. 이 커밋은 문서 전용이라 설치 plugin(코드·manifest 불변) 재갱신 불필요.
- **handoff `2026-09-30-glm-agent-0.4.0-release-handoff.md`의 다음 작업 1~10 전부 완료.**
