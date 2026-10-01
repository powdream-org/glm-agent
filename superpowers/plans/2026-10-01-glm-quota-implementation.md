# glm-agent quota 조회와 gate skill 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `glm-agent quota` 서브커맨드(Z.ai monitor API를 1회 호출해 창별 credit 수치를 `KEY=VALUE`로 출력)와 `glm-agent:quota` skill(그 수치로 GLM/native Claude를 고르는 판정표)을 추가하고, 문서(`--help`, README, AGENTS.md)를 맞춘 뒤 버전을 0.5.0으로 올린다.

**Architecture:** CLI는 수치만 출력하고 판정 기준은 skill 문서에 둔다(spec 접근 B). `cmd_quota`는 `glm-agent` 안의 단일 Bash 함수이며 `curl -H @-`로 key를 stdin 헤더로만 전달한다. 응답 본문은 `<GLM_AGENT_HOME>/quota/`에 temp 파일 + `mv`로 저장하고, 실패 분류는 기존 `classify_error_kind`를 재사용한다. 테스트는 `$FAKE_BIN`에 fake `curl`을 추가해 네트워크와 실제 key 없이 검증한다.

**Tech Stack:** Bash 3.2 호환(macOS `/bin/bash`), `curl`(7.55+, `-H @-`), `jq`(파싱 전부), 기존 hermetic 테스트 하네스(`tests/test_glm_agent.sh`, `tests/test_plugin.sh`), `shellcheck`, `claude plugin validate`.

**Spec:** superpowers/specs/2026-10-01-glm-quota-design.md

## Global Constraints

**실행 규칙**

- 모든 명령은 worktree 루트 `/Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota`에서 실행한다. `cd`를 직접 쓰지 않고 서브셸 `(cd <root> && <command>)`로 감싼다. 아래 명령은 이 형태로 적혀 있다.
- Edit 단계의 `old_string`은 HEAD(35a58e3) 기준 앵커 텍스트이고 파일 안에서 유일하다. 줄 번호는 HEAD 기준 참고용이며 앞선 Task로 밀린다.
- 커밋은 `git add <exact paths>`로 지정한 파일만 stage한다. 이 계획 파일(`superpowers/plans/…`)은 stage하지 않는다. push, merge, 재설치는 하지 않는다(spec 3절, 별도 승인).
- 커밋 메시지는 영어이고, 본문 마지막에 빈 줄과 `Claude-Session: https://claude.ai/code/session_012m3Tn7s4e1LsFVkk4p5xPV`를 붙인다.

**코드 규칙 (모든 코드 블록에 적용)**

- Bash는 macOS `/bin/bash` 3.2에서 동작해야 한다: 연관 배열, `mapfile`/`readarray`, `${var,,}`, `|&`, 음수 배열 인덱스를 쓰지 않는다. `bash -n`과 `shellcheck`를 통과해야 한다.
- 기존 CLI 스타일을 따른다: `die`(exit 2), `require_command`, `load_api_key`, `validate_single_line`, `printf`로 `KEY=VALUE` 출력, `main()`의 `case` 분기, `usage()` heredoc.
- jq 프로그램은 `quota_render_jq()` 안의 quoted heredoc에 둔다. 변수에 작은따옴표 문자열로 넣으면 shellcheck SC2016이 걸리기 때문이다.
- 테스트 코드에서 `rm -rf`를 쓰지 않는다. 임시 디렉터리는 `$TEST_ROOT` 아래에 만들고 기존 `cleanup`이 지운다.

**key 보안**

- key는 argv, stdout, stderr, 파일 어디에도 나타나지 않는다. 헤더는 `printf`(shell builtin)로 만들어 curl의 stdin(`-H @-`)으로 전달한다.
- key는 `validate_single_line "API key" "$ZAI_API_KEY"`로 한 줄임을 확인한 뒤에만 쓴다(CR/LF header injection 방지). 이 검사는 `ensure_state_home`, `mktemp`, curl 호출보다 앞에 있어야 한다.

**curl 호출은 하나다** (fake curl이 정확히 이 플래그만 받아들인다)

```bash
printf 'Authorization: %s\n' "$ZAI_API_KEY" |
  curl -sS --connect-timeout 5 --max-time 10 \
    -H @- -H 'Accept-Language: en-US,en' \
    -o "$response_tmp" -w '%{http_code}' "$url" 2>"$stderr_tmp"
```

- `$response_tmp`와 `$stderr_tmp`는 `<GLM_AGENT_HOME>/quota/` 안의 `mktemp` 파일이고, 파싱과 분류가 끝난 뒤 `mv -f`로 `response.json`과 `stderr.log`가 된다. 동시 실행이 반쯤 쓰인 `response.json`을 남기지 않는다.
- URL은 `ZAI_BASE_URL`의 scheme+host(+port)에 `/api/monitor/usage/quota/limit`을 붙인 것이다. `^(https?://[A-Za-z0-9.-]+(:[0-9]+)?)(/|$)`에 맞지 않으면 exit 2다(userinfo, query, 잘못된 port 포함).

**JSON 규칙**

- 파싱은 jq만 쓴다. null 또는 누락된 숫자 필드는 빈 값으로 출력하고 문자열 `null`을 출력하지 않는다.
- `RESET_AT`은 `nextResetTime`이 숫자일 때만 `(. / 1000 | floor | todate)`이고 아니면 빈 값이다.
- `WINDOW`는 unit 3이면 `<number>h`, unit 6이면 `<number>w`, 그 밖에는 `u<unit>x<number>`이다. `unit`이나 `number`가 숫자가 아니면 빈 값이다.
- 본문은 "JSON 객체 정확히 1개"일 때만 유효하다(`jq -e -s 'length == 1 and (.[0] | type) == "object"'`). 뒤에 쓰레기가 붙거나, 문서가 2개이거나, 비어 있으면 유효하지 않다.

**검증 상태**

이 계획의 코드는 scratchpad 복제본에 그대로 적용해 확인했다. 전체 `tests/test_glm_agent.sh`(503개)와 `tests/test_plugin.sh`(79개)가 bash 5.3과 macOS `/bin/bash` 3.2.57에서 통과했고, `shellcheck` 0.11, `bash -n`, `claude plugin validate --strict .`도 통과했다. 각 Task의 "FAIL 예상" 출력은 그 복제본에서 실제로 관측한 값이다.

**Spec이 침묵하거나 보완한 지점** (리뷰에서 User 확인이 필요하다)

1. `Accept-Language: en-US,en` 헤더와 `-sS`는 spec 5절 요청 표에 없다. 요청 지시로 추가했고, 영어 오류 메시지를 받기 위한 것이다.
2. spec 5.2는 `PLAN_LEVEL`·`TYPE`을 "서버 값 그대로"로 쓰지만, 계획은 서버 문자열의 제어 문자(개행 포함)를 공백으로 바꾼다. 서버 값이 `QUOTA_STATUS=` 같은 줄을 위조하는 것을 막기 위해서다. 정상 값은 달라지지 않는다.
3. spec 5.3 4행을 글자 그대로 읽는다: 본문의 숫자 `code`가 200이 아니거나(누락 포함) `success`가 `true`가 아니면 4행이다. 따라서 HTTP 200 + `{}` 같은 본문은 `invalid-response`가 아니라 `provider-error`다.
4. skill의 exit status 2(사용법·설정 오류, `QUOTA_STATUS` 줄 없음) 처리는 spec 6.2 판정표에 없었다. 메인 판정(2026-10-01): skill은 stderr 메시지를 User에게 보고하고 1행처럼 native Claude로 보낸다. 근거: exit 2의 실제 원인 중 key 미설정·`jq` 없음·`ZAI_BASE_URL` 형식 위반은 GLM worker도 똑같이 멈춘다. `curl` 없음만 GLM이 동작한다. spec 6.2에도 반영했다.
5. `curl -H @-`는 curl 7.55 이상이 필요하다. help와 README에 최소 버전을 적는다.
6. AGENTS.md에는 spec 9절이 요구한 `skills/` 줄 외에, 테스트 파일 설명 두 줄과 "key는 stdin 헤더로만 전달" invariant 한 줄을 추가한다.

## Review Focus

리뷰어가 가장 먼저 확인할 다섯 항목이다. 각 항목의 테스트는 소유 Task에 들어 있다.

1. **key에 CR/LF가 있는 경우 (Task 1).** `ZAI_API_KEY=$'abc\rdef'`와 `$'abc\ndef'`는 curl을 호출하기 전에 exit 2로 끝나야 한다. 테스트가 fake curl 로그가 비어 있음을 확인한다.
2. **`limits: []` (Task 1).** `QUOTA_STATUS=OK`, `LIMIT_COUNT=0`, `LIMIT_1_` 줄 없음, exit 0이다. "항목 없음"을 실패로 분류하면 안 된다.
3. **한 limit에 `remaining`/`nextResetTime`이 없거나 `level`이 null (Task 1, Task 3).** 출력은 빈 값이고 `null`이 나오지 않는다. skill 본문은 빈 `REMAINING`을 0으로 읽지 않는다고 명시한다.
4. **HTTP 200 + `success:true` + `data:null` (Task 2).** `invalid-response`, exit 1이다. `data.limits`가 배열인지 확인하는 jq 식이 `data`가 null·문자열·배열이어도 에러 없이 `other`로 떨어져야 한다.
5. **본문의 BOM과 뒤따르는 쓰레기 (Task 2).** UTF-8 BOM이 붙은 유효한 JSON은 성공(jq가 BOM을 제거한다)이고, JSON 뒤에 글자가 붙은 본문은 `invalid-response`다. 이 둘이 같은 검사(`jq -e -s`)에서 갈린다.

---

### Task 1: `quota` 성공 경로와 인자·설정 검증

`glm-agent quota`가 fake curl 응답을 5.1절 모양으로 출력하고, 요청 형태(URL, 플래그, stdin 헤더)와 raw 산출물을 spec대로 만든다. 인자·key·`ZAI_BASE_URL`·의존 도구 오류는 exit 2다. 요청 실패(curl 오류, HTTP 비-200)의 분류는 Task 2이며, 이 Task에서는 임시로 `die`(exit 2)한다.

**Files:**
- Modify: `glm-agent` — (a) 새 블록(상수, `quota_render_jq`, `quota_endpoint_url`, `cmd_quota`)을 `main() {`(2107행) 바로 앞에 삽입, (b) `main()`의 `close)` 분기(2157–2160행)와 `_execute-turn)`(2161행) 사이에 `quota)` 분기 추가.
- Test: `tests/test_glm_agent.sh` — 마지막 `printf '1..%d\n' "$tests"`(1820행) 바로 앞에 quota 블록 삽입. fake curl은 `$FAKE_BIN`(13행 정의, 293행에서 PATH 맨 앞)에 만든다.
- 읽기 전용으로 재사용: `glm-agent`의 `die`(192–195), `require_command`(197–201), `validate_single_line`(203–208), `ensure_state_home`(227–230), `load_api_key`(232–242); 테스트의 `pass`/`fail`/`assert_eq`/`assert_contains`/`assert_not_contains`/`capture`/`file_mode`(325–386).

**Interfaces:**
- Consumes: `die <message...>`(exit 2), `require_command <name>`, `validate_single_line <label> <value>`, `ensure_state_home`, `load_api_key`(`ZAI_API_KEY` 설정), 전역 `GLM_AGENT_HOME`(절대경로로 정규화됨, 13–15행), `ZAI_BASE_URL`(20행), `ZAI_API_KEY`.
- Produces (CLI): 상수 `QUOTA_ENDPOINT_PATH`, `quota_render_jq`(인자 없음, jq 프로그램을 stdout으로 출력), `quota_endpoint_url`(인자 없음, `ZAI_BASE_URL`을 읽어 URL 출력 또는 `die`), `cmd_quota "$@"`(인자가 있으면 `die`).
- Produces (테스트): `quota_case <http-status> <body-file-or-empty> <curl-exit> [VAR=value ...]`(`OUTPUT`/`RC`/`STDERR` 설정, 출력을 `QUOTA_SEEN`에 누적), `make_quota_bin <dir> <tool-to-omit>`, fake curl 제어 env `FAKE_CURL_STATUS`/`FAKE_CURL_BODY_FILE`/`FAKE_CURL_EXIT`/`FAKE_CURL_LOG`(argv, 한 줄에 `arg=<값>`)/`FAKE_CURL_STDIN`(stdin 전문), fixture 디렉터리 `$QUOTA_FIXTURES`와 `ok.json`, `zero.json`, `time-limit.json`, `unknown-window.json`, `empty-limits.json`, `sparse.json`, `control-chars.json`, 변수 `expected_quota_ok`(5.1절 stdout 전문).

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_glm_agent.sh`에서 `printf '1..%d\n' "$tests"` 줄 바로 앞에 아래 블록을 삽입한다(Edit: `old_string`은 `printf '1..%d\n' "$tests"` 한 줄, `new_string`은 아래 블록 + 그 줄).

```bash
# --- quota: fake curl, fixtures, and helpers --------------------------------
QUOTA_KEY='zk-quota-test-0123456789abcdef'
QUOTA_HOME="$TEST_ROOT/quota-home"
QUOTA_FIXTURES="$TEST_ROOT/quota-fixtures"
FAKE_CURL_LOG="$TEST_ROOT/curl.argv"
FAKE_CURL_STDIN="$TEST_ROOT/curl.stdin"
QUOTA_SEEN=''
mkdir -p "$QUOTA_FIXTURES"

cat >"$FAKE_BIN/curl" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail

# Fake curl for glm-agent quota tests: no network access, no real key.
# It accepts exactly the flags glm-agent quota uses and rejects anything else.
log="${FAKE_CURL_LOG:?}"
: >>"$log"
for arg in "$@"; do
  printf 'arg=%s\n' "$arg" >>"$log"
done

output=''
write_out=''
url=''
silent=0
stdin_header=0
language_header=0
while (($# > 0)); do
  case "$1" in
    -sS) silent=1; shift ;;
    --connect-timeout|--max-time) shift 2 ;;
    -H)
      case "$2" in
        @-) stdin_header=1 ;;
        'Accept-Language: en-US,en') language_header=1 ;;
        *) printf 'fake curl: unexpected header\n' >&2; exit 99 ;;
      esac
      shift 2
      ;;
    -o) output="$2"; shift 2 ;;
    -w) write_out="$2"; shift 2 ;;
    -*) printf 'fake curl: unexpected option: %s\n' "$1" >&2; exit 99 ;;
    *) url="$1"; shift ;;
  esac
done

if ((silent != 1 || stdin_header != 1 || language_header != 1)) ||
  [[ -z "$output" || -z "$url" || "$write_out" != '%{http_code}' ]]; then
  printf 'fake curl: incomplete invocation\n' >&2
  exit 99
fi

cat >"${FAKE_CURL_STDIN:?}"

curl_exit="${FAKE_CURL_EXIT:-0}"
if ((curl_exit != 0)); then
  printf 'curl: (%s) fake failure\n' "$curl_exit" >&2
  printf '000'
  exit "$curl_exit"
fi

if [[ -n "${FAKE_CURL_BODY_FILE:-}" ]]; then
  cp "$FAKE_CURL_BODY_FILE" "$output"
fi
printf '%s' "${FAKE_CURL_STATUS:-200}"
FAKE
chmod +x "$FAKE_BIN/curl"

cat >"$QUOTA_FIXTURES/ok.json" <<'JSON'
{"code":200,"msg":"Operation successful","data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":1450,"remaining":549,"percentage":72,"nextResetTime":1790791395020},{"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":7974,"remaining":2025,"percentage":79,"nextResetTime":1791162764983}],"level":"lite"},"success":true}
JSON
jq '.data.limits[0].remaining = 0' "$QUOTA_FIXTURES/ok.json" \
  >"$QUOTA_FIXTURES/zero.json"
jq '.data.limits += [{"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":20,"remaining":980,"percentage":2,"nextResetTime":1793000000000}]' \
  "$QUOTA_FIXTURES/ok.json" >"$QUOTA_FIXTURES/time-limit.json"
jq '.data.limits[0].unit = 9 | .data.limits[0].number = 2' \
  "$QUOTA_FIXTURES/ok.json" >"$QUOTA_FIXTURES/unknown-window.json"
jq '.data.limits = []' "$QUOTA_FIXTURES/ok.json" \
  >"$QUOTA_FIXTURES/empty-limits.json"
jq 'del(.data.limits[0].remaining, .data.limits[0].nextResetTime) | .data.level = null' \
  "$QUOTA_FIXTURES/ok.json" >"$QUOTA_FIXTURES/sparse.json"
jq '.data.level = "li\nQUOTA_STATUS=FORGED"' "$QUOTA_FIXTURES/ok.json" \
  >"$QUOTA_FIXTURES/control-chars.json"

# quota_case <http-status> <body-file-or-empty> <curl-exit> [VAR=value ...]
# Runs "glm-agent quota" against the fake curl and records everything printed
# so the final scan can prove the API key never reached stdout or stderr.
quota_case() {
  local status="$1" body="$2" curl_exit="$3"
  shift 3
  : >"$FAKE_CURL_LOG"
  : >"$FAKE_CURL_STDIN"
  capture env -u ZAI_BASE_URL ZAI_API_KEY="$QUOTA_KEY" \
    GLM_AGENT_HOME="$QUOTA_HOME" FAKE_CURL_STATUS="$status" \
    FAKE_CURL_BODY_FILE="$body" FAKE_CURL_EXIT="$curl_exit" \
    FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_CURL_STDIN="$FAKE_CURL_STDIN" \
    "$@" "$SCRIPT" quota
  QUOTA_SEEN+="$OUTPUT"$'\n'"$STDERR"$'\n'
}

# make_quota_bin <dir> <tool-to-omit>: a PATH holding only what quota needs.
make_quota_bin() {
  local dir="$1" omit="$2" tool
  mkdir -p "$dir"
  for tool in dirname mkdir chmod mktemp mv cat jq curl; do
    if [[ "$tool" != "$omit" ]]; then
      ln -sf "$(command -v "$tool")" "$dir/$tool"
    fi
  done
}

# --- quota: probe response, request shape, raw artifacts ---------------------
expected_quota_ok="$(cat <<EOF
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
RESPONSE=$QUOTA_HOME/quota/response.json
ERROR_KIND=
PROVIDER_CODE=
EOF
)"

quota_case 200 "$QUOTA_FIXTURES/ok.json" 0
assert_eq 'quota succeeds on the probe response' '0' "$RC"
assert_eq 'quota prints the documented fields' "$expected_quota_ok" "$OUTPUT"
assert_eq 'quota stderr is empty on success' '' "$STDERR"

quota_argv="$(cat "$FAKE_CURL_LOG")"
assert_contains 'quota runs curl silently with errors' "$quota_argv" $'arg=-sS\n'
assert_contains 'quota bounds connect and total time' "$quota_argv" \
  $'arg=--connect-timeout\narg=5\narg=--max-time\narg=10\n'
assert_contains 'quota reads the auth header from stdin' "$quota_argv" \
  $'arg=-H\narg=@-\n'
assert_contains 'quota asks for English messages' "$quota_argv" \
  $'arg=-H\narg=Accept-Language: en-US,en\n'
assert_contains 'quota prints only the HTTP status on curl stdout' \
  "$quota_argv" $'arg=-w\narg=%{http_code}\n'
assert_contains 'quota writes the body inside its own state directory' \
  "$quota_argv" $'arg=-o\narg='"$QUOTA_HOME/quota/.response."
assert_eq 'quota targets the monitor endpoint' \
  'arg=https://api.z.ai/api/monitor/usage/quota/limit' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"
assert_not_contains 'quota keeps the API key out of curl argv' \
  "$quota_argv" "$QUOTA_KEY"
assert_eq 'quota sends the key only as one stdin header line' \
  "Authorization: $QUOTA_KEY" "$(cat "$FAKE_CURL_STDIN")"

assert_eq 'quota keeps exactly the two raw artifacts' \
  $'response.json\nstderr.log' "$(ls -A "$QUOTA_HOME/quota")"
assert_eq 'quota stores the raw response body' \
  "$(cat "$QUOTA_FIXTURES/ok.json")" "$(cat "$QUOTA_HOME/quota/response.json")"
assert_eq 'quota state home stays private' '700' "$(file_mode "$QUOTA_HOME")"
assert_eq 'quota directory is private' '700' "$(file_mode "$QUOTA_HOME/quota")"
assert_eq 'quota response file is private' '600' \
  "$(file_mode "$QUOTA_HOME/quota/response.json")"

quota_case 200 "$QUOTA_FIXTURES/zero.json" 0
assert_eq 'quota overwrites the raw response on each call' \
  "$(cat "$QUOTA_FIXTURES/zero.json")" "$(cat "$QUOTA_HOME/quota/response.json")"

# --- quota: field mapping ----------------------------------------------------
assert_eq 'exhausted window is still a successful lookup' '0' "$RC"
assert_contains 'quota reports a zero remainder as 0' "$OUTPUT" \
  $'LIMIT_1_REMAINING=0\n'

quota_case 200 "$QUOTA_FIXTURES/time-limit.json" 0
assert_eq 'TIME_LIMIT entry keeps the lookup successful' '0' "$RC"
assert_contains 'quota counts every limit entry' "$OUTPUT" $'LIMIT_COUNT=3\n'
assert_contains 'quota prints the third entry type verbatim' "$OUTPUT" \
  $'LIMIT_3_TYPE=TIME_LIMIT\n'
assert_contains 'quota prints the third entry reset in UTC' "$OUTPUT" \
  $'LIMIT_3_RESET_AT=2026-10-26T07:33:20Z\n'

quota_case 200 "$QUOTA_FIXTURES/unknown-window.json" 0
assert_contains 'unknown unit keeps its code and number' "$OUTPUT" \
  $'LIMIT_1_WINDOW=u9x2\n'

quota_case 200 "$QUOTA_FIXTURES/empty-limits.json" 0
assert_eq 'empty limits list is still a successful lookup' '0' "$RC"
assert_contains 'empty limits list reports LIMIT_COUNT=0' "$OUTPUT" \
  $'LIMIT_COUNT=0\n'
assert_not_contains 'empty limits list prints no limit lines' "$OUTPUT" \
  'LIMIT_1_'

quota_case 200 "$QUOTA_FIXTURES/sparse.json" 0
assert_eq 'limit missing remaining and reset time is still successful' '0' "$RC"
assert_contains 'missing remaining prints an empty value' "$OUTPUT" \
  $'LIMIT_1_REMAINING=\n'
assert_contains 'missing reset time prints an empty value' "$OUTPUT" \
  $'LIMIT_1_RESET_AT=\nLIMIT_2_TYPE='
assert_contains 'null plan level prints an empty value' "$OUTPUT" \
  $'PLAN_LEVEL=\n'
assert_not_contains 'null and missing fields never print the word null' \
  "$OUTPUT" 'null'

quota_case 200 "$QUOTA_FIXTURES/control-chars.json" 0
assert_contains 'server control characters cannot start a new output line' \
  "$OUTPUT" $'PLAN_LEVEL=li QUOTA_STATUS=FORGED\n'
assert_eq 'exactly one QUOTA_STATUS line is printed' '1' \
  "$(printf '%s\n' "$OUTPUT" | grep -c '^QUOTA_STATUS=')"

# --- quota: endpoint follows ZAI_BASE_URL host and port ----------------------
quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 \
  ZAI_BASE_URL=https://example.test:8443/api/anthropic
assert_eq 'quota keeps scheme host and port and drops the base path' \
  'arg=https://example.test:8443/api/monitor/usage/quota/limit' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"

quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 ZAI_BASE_URL=http://127.0.0.1:9000
assert_eq 'quota accepts a base URL with a port and no path' \
  'arg=http://127.0.0.1:9000/api/monitor/usage/quota/limit' \
  "$(tail -n 1 "$FAKE_CURL_LOG")"

# --- quota: usage and configuration errors (exit 2, empty stdout) ------------
capture env ZAI_API_KEY="$QUOTA_KEY" GLM_AGENT_HOME="$QUOTA_HOME" \
  "$SCRIPT" quota extra
assert_eq 'quota rejects extra arguments' '2|' "$RC|$OUTPUT"
assert_contains 'quota argument error is clear' "$STDERR" \
  'quota does not accept arguments'

for bad_key in $'abc\rdef' $'abc\ndef'; do
  quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 ZAI_API_KEY="$bad_key"
  assert_eq 'multi-line API key is rejected before curl runs' \
    '2||' "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
  assert_contains 'multi-line API key error names the problem' "$STDERR" \
    'API key must be a single line'
done

for bad_url in 'ftp://example.test' 'example.test/x' \
  'https://user@example.test/x' 'https://example.test:8a/x' \
  'https://example.test?x=1'; do
  quota_case 200 "$QUOTA_FIXTURES/ok.json" 0 ZAI_BASE_URL="$bad_url"
  assert_eq "ZAI_BASE_URL [$bad_url] is rejected before curl runs" \
    '2||' "$RC|$OUTPUT|$(cat "$FAKE_CURL_LOG")"
done

nokey_home="$TEST_ROOT/quota-nokey-home"
capture env -u ZAI_API_KEY GLM_AGENT_HOME="$nokey_home" "$SCRIPT" quota
assert_eq 'quota without a key is a configuration error' '2|' "$RC|$OUTPUT"
assert_contains 'quota key error gives the setup instruction' "$STDERR" \
  'Run: glm-agent api-key'
if [[ ! -e "$nokey_home" ]]; then
  pass 'quota without a key creates no state'
else
  fail 'quota without a key creates no state' "unexpected path: $nokey_home"
fi

emptykey_home="$TEST_ROOT/quota-emptykey-home"
mkdir -p "$emptykey_home"
: >"$emptykey_home/.env.auth"
capture env -u ZAI_API_KEY GLM_AGENT_HOME="$emptykey_home" "$SCRIPT" quota
assert_eq 'quota with an empty stored key is a configuration error' \
  '2|' "$RC|$OUTPUT"
assert_contains 'quota empty key error is clear' "$STDERR" \
  'stored API key is empty'

make_quota_bin "$TEST_ROOT/quota-bin-no-curl" curl
capture env PATH="$TEST_ROOT/quota-bin-no-curl" ZAI_API_KEY="$QUOTA_KEY" \
  GLM_AGENT_HOME="$QUOTA_HOME" "$BASH" "$SCRIPT" quota
assert_eq 'quota without curl is a dependency error' '2|' "$RC|$OUTPUT"
assert_contains 'quota names the missing curl' "$STDERR" \
  'required command not found: curl'

make_quota_bin "$TEST_ROOT/quota-bin-no-jq" jq
capture env PATH="$TEST_ROOT/quota-bin-no-jq" ZAI_API_KEY="$QUOTA_KEY" \
  GLM_AGENT_HOME="$QUOTA_HOME" "$BASH" "$SCRIPT" quota
assert_eq 'quota without jq is a dependency error' '2|' "$RC|$OUTPUT"
assert_contains 'quota names the missing jq' "$STDERR" \
  'required command not found: jq'

# --- quota: the API key is never printed or stored ---------------------------
assert_not_contains 'quota success and configuration cases never print the key' \
  "$QUOTA_SEEN" "$QUOTA_KEY"
if grep -rqF -- "$QUOTA_KEY" "$QUOTA_HOME"; then
  fail 'quota state files never contain the key' "key found under $QUOTA_HOME"
else
  pass 'quota state files never contain the key'
fi

```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_glm_agent.sh > /dev/null)
```

Expected: exit status 1. stderr 끝에 `# 41 test(s) failed`가 나온다. 구현 전이라 `quota`가 `unknown command`(exit 2)이므로 새 테스트 59개 중 41개가 FAIL이고, exit 2와 빈 stdout을 기대하는 18개는 우연히 PASS한다. stdout으로 확인하려면 `bash tests/test_glm_agent.sh | grep -A1 '^not ok' | head` 를 쓴다. 첫 실패는 다음과 같다(기존 테스트 399개가 앞서 통과한다).

```text
not ok 400 - quota succeeds on the probe response
  expected [0], got [2]
```

stderr에 `cat: …/quota-home/quota/response.json: No such file or directory` 같은 줄이 섞이는 것은 구현 전이라서 정상이다.

- [ ] **Step 3: 최소 구현**

(3a) `glm-agent`에서 아래 Edit를 한다. `old_string`은 다음 두 줄이다.

```text
main() {
  local command="${1:-}"
```

`new_string`은 아래 블록 + 위 두 줄이다.

```bash
QUOTA_ENDPOINT_PATH='/api/monitor/usage/quota/limit'

# jq program for a successful quota response. It prints KEY=VALUE lines;
# missing numbers print empty and server strings lose control characters.
quota_render_jq() {
  cat <<'JQ'
def str:
  if type == "string" then gsub("[[:cntrl:]]"; " ")
  elif type == "number" or type == "boolean" then tostring
  else "" end;
def num: if type == "number" then tostring else "" end;
def window:
  if (.unit | type) == "number" and (.number | type) == "number" then
    if .unit == 3 then "\(.number)h"
    elif .unit == 6 then "\(.number)w"
    else "u\(.unit)x\(.number)" end
  else "" end;
def reset_at:
  if (.nextResetTime | type) == "number"
  then (try (.nextResetTime / 1000 | floor | todate) catch "")
  else "" end;
.data as $data
| ($data.limits | length) as $count
| "QUOTA_STATUS=OK",
  "PLAN_LEVEL=\($data.level | str)",
  "LIMIT_COUNT=\($count)",
  (range(0; $count) as $i
    | ($i + 1) as $n
    | ($data.limits[$i] | if type == "object" then . else {} end) as $limit
    | "LIMIT_\($n)_TYPE=\($limit.type | str)",
      "LIMIT_\($n)_WINDOW=\($limit | window)",
      "LIMIT_\($n)_TOTAL=\($limit.usage | num)",
      "LIMIT_\($n)_USED=\($limit.currentValue | num)",
      "LIMIT_\($n)_REMAINING=\($limit.remaining | num)",
      "LIMIT_\($n)_USED_PERCENT=\($limit.percentage | num)",
      "LIMIT_\($n)_RESET_AT=\($limit | reset_at)")
JQ
}

quota_endpoint_url() {
  local base_pattern='^(https?://[A-Za-z0-9.-]+(:[0-9]+)?)(/|$)'

  [[ "$ZAI_BASE_URL" =~ $base_pattern ]] ||
    die "ZAI_BASE_URL must look like http(s)://host[:port][/path]"
  printf '%s%s\n' "${BASH_REMATCH[1]}" "$QUOTA_ENDPOINT_PATH"
}

cmd_quota() {
  (($# == 0)) || die "quota does not accept arguments"
  require_command curl
  require_command jq

  local url
  url="$(quota_endpoint_url)"
  load_api_key
  validate_single_line "API key" "$ZAI_API_KEY"

  ensure_state_home
  local quota_dir="$GLM_AGENT_HOME/quota"
  local response_file="$quota_dir/response.json"
  local stderr_file="$quota_dir/stderr.log"
  mkdir -p "$quota_dir"
  chmod 700 "$quota_dir"

  local response_tmp stderr_tmp
  response_tmp="$(mktemp "$quota_dir/.response.XXXXXX")"
  stderr_tmp="$(mktemp "$quota_dir/.stderr.XXXXXX")"

  # The key travels only as a header line on curl's stdin (printf is a shell
  # builtin), so it never appears in any process argument list.
  local http_code curl_status=0
  http_code="$(
    printf 'Authorization: %s\n' "$ZAI_API_KEY" |
      curl -sS --connect-timeout 5 --max-time 10 \
        -H @- -H 'Accept-Language: en-US,en' \
        -o "$response_tmp" -w '%{http_code}' "$url" 2>"$stderr_tmp"
  )" || curl_status=$?

  if ((curl_status != 0)) || [[ "$http_code" != 200 ]]; then
    die "quota request failed (curl exit $curl_status, HTTP $http_code)"
  fi

  local rendered
  rendered="$(jq -r "$(quota_render_jq)" "$response_tmp")"

  mv -f "$response_tmp" "$response_file"
  mv -f "$stderr_tmp" "$stderr_file"

  printf '%s\n' "$rendered"
  printf 'RESPONSE=%s\n' "$response_file"
  printf 'ERROR_KIND=\n'
  printf 'PROVIDER_CODE=\n'
}

main() {
  local command="${1:-}"
```

(3b) 같은 파일의 `main()`에서 두 번째 Edit를 한다. `old_string`:

```text
      cmd_close "$@"
      ;;
    _execute-turn)
```

`new_string`:

```text
      cmd_close "$@"
      ;;
    quota)
      shift
      cmd_quota "$@"
      ;;
    _execute-turn)
```

- [ ] **Step 4: 테스트가 통과하는지 확인**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_glm_agent.sh | tail -2)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash -n glm-agent tests/test_glm_agent.sh && shellcheck glm-agent tests/test_glm_agent.sh)
```

Expected:

```text
1..458
# all 458 tests passed
```

`bash -n`과 `shellcheck`는 출력 없이 exit 0이다.

- [ ] **Step 5: 커밋**

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && git add glm-agent tests/test_glm_agent.sh && git commit -m "$(cat <<'EOF'
feat: add quota command for Z.ai credit limits

Claude-Session: https://claude.ai/code/session_012m3Tn7s4e1LsFVkk4p5xPV
EOF
)")
```

---

### Task 2: 실패 분류와 실패 stdout

spec 5.3의 1–6행을 구현한다. 실패는 `QUOTA_STATUS=INVALID` 네 줄과 exit 1이고, raw 산출물(`response.json`, `stderr.log`)은 실패에도 남긴다. Task 1의 임시 `die`를 이 분류로 대체한다.

**Files:**
- Modify: `glm-agent` — `cmd_quota` 안에서, Task 1이 만든 `if ((curl_status != 0)) || [[ "$http_code" != 200 ]]; then` 블록부터 함수 끝 `}`까지를 교체한다.
- Test: `tests/test_glm_agent.sh` — 마지막 `printf '1..%d\n' "$tests"` 바로 앞(Task 1 블록 뒤)에 삽입.
- 읽기 전용으로 재사용: `classify_error_kind <provider-code> <default-kind>`(`glm-agent` 928–942행; 분류표를 복제하지 않는다), Task 1의 `quota_case`, `QUOTA_FIXTURES`, `QUOTA_HOME`, `expected_quota_ok`.

**Interfaces:**
- Consumes: `classify_error_kind <provider-code> <default-kind>`, `quota_render_jq`, `cmd_quota` 안의 `curl_status`/`http_code`/`response_tmp`/`stderr_tmp`/`response_file`/`stderr_file`.
- Produces (CLI): `cmd_quota`가 성공이면 exit 0, 조회 실패면 `QUOTA_STATUS=INVALID`/`RESPONSE=`/`ERROR_KIND=`/`PROVIDER_CODE=` 네 줄을 출력하고 `return 1`(exit 1). `PROVIDER_CODE`는 본문이 유효한 JSON 객체이고 숫자 `code`가 200이 아닐 때만 그 값이다(HTTP 상태와 무관).
- Produces (테스트): `assert_quota_failure <name> <error-kind> <provider-code>`(exit 1과 네 줄 stdout 전문을 한 번에 검사), 추가 fixture(`code-1001.json`, `code-1113.json`, `code-1302.json`, `code-1211.json`, `code-9999.json`, `code-404.json`, `declined-200.json`, `no-limits.json`, `data-null.json`, `not-json.txt`, `array.json`, `trailing-garbage.json`, `bom.json`). Task 4가 `expected_quota_ok`를 다시 쓴다.

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_glm_agent.sh`에서 `printf '1..%d\n' "$tests"` 줄 바로 앞(Task 1 블록 바로 뒤)에 아래 블록을 삽입한다.

```bash
# --- quota: failure classification (exit 1, QUOTA_STATUS=INVALID) ------------
QUOTA_SEEN=''

cat >"$QUOTA_FIXTURES/code-1001.json" <<'JSON'
{"code":1001,"msg":"Header Authorization missing or invalid","success":false}
JSON
cat >"$QUOTA_FIXTURES/code-1113.json" <<'JSON'
{"code":1113,"msg":"Insufficient balance","success":false}
JSON
cat >"$QUOTA_FIXTURES/code-1302.json" <<'JSON'
{"code":1302,"msg":"Rate limit reached","success":false}
JSON
cat >"$QUOTA_FIXTURES/code-1211.json" <<'JSON'
{"code":1211,"msg":"Unknown model","success":false}
JSON
cat >"$QUOTA_FIXTURES/code-9999.json" <<'JSON'
{"code":9999,"msg":"Unexpected","success":false}
JSON
cat >"$QUOTA_FIXTURES/code-404.json" <<'JSON'
{"code":404,"msg":"Not found","success":false}
JSON
cat >"$QUOTA_FIXTURES/declined-200.json" <<'JSON'
{"code":200,"msg":"declined","success":false}
JSON
cat >"$QUOTA_FIXTURES/no-limits.json" <<'JSON'
{"code":200,"msg":"ok","data":{"level":"lite"},"success":true}
JSON
cat >"$QUOTA_FIXTURES/data-null.json" <<'JSON'
{"code":200,"msg":"ok","data":null,"success":true}
JSON
printf '%s\n' '<html>bad gateway</html>' >"$QUOTA_FIXTURES/not-json.txt"
printf '%s\n' '[]' >"$QUOTA_FIXTURES/array.json"
{ cat "$QUOTA_FIXTURES/ok.json"; printf 'trailing garbage\n'; } \
  >"$QUOTA_FIXTURES/trailing-garbage.json"
{ printf '\357\273\277'; cat "$QUOTA_FIXTURES/ok.json"; } \
  >"$QUOTA_FIXTURES/bom.json"

# assert_quota_failure <name> <error-kind> <provider-code>
# Checks the exit status and the complete four-line failure output.
assert_quota_failure() {
  local name="$1" kind="$2" code="$3" expected
  expected="$(printf 'QUOTA_STATUS=INVALID\nRESPONSE=%s\nERROR_KIND=%s\nPROVIDER_CODE=%s' \
    "$QUOTA_HOME/quota/response.json" "$kind" "$code")"
  assert_eq "$name" "1|$expected" "$RC|$OUTPUT"
}

# Rows 1-3: transport and HTTP status decide before the body is read.
quota_case 000 '' 28
assert_quota_failure 'curl timeout is provider-transient' provider-transient ''
assert_eq 'curl failure leaves an empty raw response' '' \
  "$(cat "$QUOTA_HOME/quota/response.json")"
assert_contains 'curl failure keeps curl stderr' \
  "$(cat "$QUOTA_HOME/quota/stderr.log")" 'curl: (28)'
quota_case 000 '' 6
assert_quota_failure 'curl network error is provider-transient' \
  provider-transient ''
quota_case 401 '' 0
assert_quota_failure 'HTTP 401 is authentication' authentication ''
quota_case 403 "$QUOTA_FIXTURES/code-1001.json" 0
assert_quota_failure 'HTTP 403 keeps the provider code' authentication 1001
assert_eq 'HTTP failure keeps the raw body' \
  "$(cat "$QUOTA_FIXTURES/code-1001.json")" \
  "$(cat "$QUOTA_HOME/quota/response.json")"
quota_case 429 '' 0
assert_quota_failure 'HTTP 429 is provider-transient' provider-transient ''
for http_status in 500 503; do
  quota_case "$http_status" '' 0
  assert_quota_failure "HTTP $http_status is provider-transient" \
    provider-transient ''
done

# Row 4: a provider error inside the body reuses classify_error_kind.
quota_case 200 "$QUOTA_FIXTURES/code-1001.json" 0
assert_quota_failure 'body code 1001 is authentication' authentication 1001
quota_case 200 "$QUOTA_FIXTURES/code-1113.json" 0
assert_quota_failure 'body code 1113 is quota-exhausted' quota-exhausted 1113
quota_case 200 "$QUOTA_FIXTURES/code-1302.json" 0
assert_quota_failure 'body code 1302 is provider-transient' \
  provider-transient 1302
quota_case 200 "$QUOTA_FIXTURES/code-1211.json" 0
assert_quota_failure 'body code 1211 is model-unavailable' \
  model-unavailable 1211
quota_case 200 "$QUOTA_FIXTURES/code-9999.json" 0
assert_quota_failure 'unlisted body code is provider-error' provider-error 9999
quota_case 200 "$QUOTA_FIXTURES/declined-200.json" 0
assert_quota_failure 'success:false with code 200 has no provider code' \
  provider-error ''

# Row 6: other non-200 statuses.
quota_case 404 "$QUOTA_FIXTURES/not-json.txt" 0
assert_quota_failure 'HTTP 404 with a text body is provider-error' \
  provider-error ''
quota_case 404 "$QUOTA_FIXTURES/code-404.json" 0
assert_quota_failure 'HTTP 404 with a JSON body keeps its code' \
  provider-error 404
quota_case 302 "$QUOTA_FIXTURES/ok.json" 0
assert_quota_failure 'HTTP 302 is never a successful lookup' provider-error ''

# Row 5: HTTP 200 whose body is not a usable quota document.
quota_case 200 "$QUOTA_FIXTURES/not-json.txt" 0
assert_quota_failure 'HTTP 200 with a text body is invalid-response' \
  invalid-response ''
quota_case 200 "$QUOTA_FIXTURES/no-limits.json" 0
assert_quota_failure 'missing data.limits is invalid-response' \
  invalid-response ''
quota_case 200 "$QUOTA_FIXTURES/data-null.json" 0
assert_quota_failure 'success:true with null data is invalid-response' \
  invalid-response ''
quota_case 200 "$QUOTA_FIXTURES/array.json" 0
assert_quota_failure 'a JSON array body is invalid-response' invalid-response ''
quota_case 200 '' 0
assert_quota_failure 'an empty body is invalid-response' invalid-response ''
quota_case 200 "$QUOTA_FIXTURES/trailing-garbage.json" 0
assert_quota_failure 'trailing garbage after the JSON is invalid-response' \
  invalid-response ''

# A UTF-8 BOM before otherwise valid JSON is accepted (jq strips it).
quota_case 200 "$QUOTA_FIXTURES/bom.json" 0
assert_eq 'a BOM-prefixed response is accepted' "0|$expected_quota_ok" \
  "$RC|$OUTPUT"

assert_eq 'failures leave exactly the two raw artifacts' \
  $'response.json\nstderr.log' "$(ls -A "$QUOTA_HOME/quota")"
assert_not_contains 'quota failure cases never print the key' \
  "$QUOTA_SEEN" "$QUOTA_KEY"
if grep -rqF -- "$QUOTA_KEY" "$QUOTA_HOME"; then
  fail 'quota failure artifacts never contain the key' \
    "key found under $QUOTA_HOME"
else
  pass 'quota failure artifacts never contain the key'
fi

```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_glm_agent.sh | grep -A2 '^not ok' | head -8)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_glm_agent.sh 2>&1 >/dev/null | tail -1)
```

Expected: 새 테스트 29개 중 26개가 FAIL이다. 임시 `die`가 exit 2를 내고 `QUOTA_STATUS=INVALID`를 출력하지 않기 때문이다. 첫 실패는 다음과 같다.

```text
not ok 459 - curl timeout is provider-transient
  expected [1|QUOTA_STATUS=INVALID
```

두 번째 명령의 마지막 줄은 `# 26 test(s) failed`이다. BOM 케이스(`a BOM-prefixed response is accepted`)는 Task 1 구현이 이미 jq로 BOM을 처리하므로 지금도 PASS한다. 회귀 방지용 테스트다.

- [ ] **Step 3: 최소 구현**

`glm-agent`의 `cmd_quota`에서 Edit를 한다. `old_string`은 Task 1이 만든 아래 블록 전체다(`if ((curl_status` 줄부터 함수의 닫는 `}`까지).

```text
  if ((curl_status != 0)) || [[ "$http_code" != 200 ]]; then
    die "quota request failed (curl exit $curl_status, HTTP $http_code)"
  fi

  local rendered
  rendered="$(jq -r "$(quota_render_jq)" "$response_tmp")"

  mv -f "$response_tmp" "$response_file"
  mv -f "$stderr_tmp" "$stderr_file"

  printf '%s\n' "$rendered"
  printf 'RESPONSE=%s\n' "$response_file"
  printf 'ERROR_KIND=\n'
  printf 'PROVIDER_CODE=\n'
}
```

`new_string`:

```bash
  case "$http_code" in
    [0-9][0-9][0-9]) ;;
    *) http_code=000 ;;
  esac

  # A body counts as JSON only when it is exactly one object; trailing
  # garbage, a second document, or an empty body all fail the check.
  local body_ok=0 api_code="" api_success="" limits_kind="" provider_code=""
  if jq -e -s 'length == 1 and (.[0] | type) == "object"' \
    "$response_tmp" >/dev/null 2>&1; then
    body_ok=1
    local fields
    fields="$(jq -r '
      ((.code | numbers | tostring) // ""),
      (if .success == true then "true" else "false" end),
      ((((.data | objects | .limits) // null) | type)
        | if . == "array" then "array" else "other" end)
    ' "$response_tmp")"
    {
      IFS= read -r api_code
      IFS= read -r api_success
      IFS= read -r limits_kind
    } <<<"$fields"
    if [[ "$api_code" != 200 ]]; then
      provider_code="$api_code"
    fi
  fi

  # Each branch is one row of the ERROR_KIND table; the first match wins.
  local error_kind=""
  if ((curl_status != 0)); then
    error_kind='provider-transient'
  elif [[ "$http_code" == 401 || "$http_code" == 403 ]]; then
    error_kind='authentication'
  elif [[ "$http_code" == 429 || "$http_code" == 5?? ]]; then
    error_kind='provider-transient'
  elif ((body_ok == 1)) &&
    [[ "$api_code" != 200 || "$api_success" != true ]]; then
    error_kind="$(classify_error_kind "$provider_code" provider-error)"
  elif [[ "$http_code" == 200 ]] &&
    { ((body_ok == 0)) || [[ "$limits_kind" != array ]]; }; then
    error_kind='invalid-response'
  elif [[ "$http_code" != 200 ]]; then
    error_kind='provider-error'
  fi

  local rendered=""
  if [[ -z "$error_kind" ]] &&
    ! rendered="$(jq -r "$(quota_render_jq)" "$response_tmp")"; then
    error_kind='invalid-response'
  fi

  mv -f "$response_tmp" "$response_file"
  mv -f "$stderr_tmp" "$stderr_file"

  if [[ -n "$error_kind" ]]; then
    printf 'QUOTA_STATUS=INVALID\n'
    printf 'RESPONSE=%s\n' "$response_file"
    printf 'ERROR_KIND=%s\n' "$error_kind"
    printf 'PROVIDER_CODE=%s\n' "$provider_code"
    return 1
  fi

  printf '%s\n' "$rendered"
  printf 'RESPONSE=%s\n' "$response_file"
  printf 'ERROR_KIND=\n'
  printf 'PROVIDER_CODE=\n'
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_glm_agent.sh | tail -2)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash -n glm-agent tests/test_glm_agent.sh && shellcheck glm-agent tests/test_glm_agent.sh)
```

Expected:

```text
1..487
# all 487 tests passed
```

`bash -n`과 `shellcheck`는 출력 없이 exit 0이다.

- [ ] **Step 5: 커밋**

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && git add glm-agent tests/test_glm_agent.sh && git commit -m "$(cat <<'EOF'
feat: classify quota lookup failures

Claude-Session: https://claude.ai/code/session_012m3Tn7s4e1LsFVkk4p5xPV
EOF
)")
```

---

### Task 3: `glm-agent:quota` skill과 plugin 계약 테스트

skill 파일을 만들고, spec 8.2의 계약(frontmatter `name`/`description`/`allowed-tools`, 본문 명령 일치, 판정표 핵심어)을 `tests/test_plugin.sh`에 추가한다. plugin 매니페스트는 `skills/`를 자동 탐색하므로 `plugin.json`/`marketplace.json`은 바꾸지 않는다.

**Files:**
- Create: `skills/quota/SKILL.md`
- Test: `tests/test_plugin.sh` — `if command -v claude >/dev/null 2>&1 &&`(225행) 바로 앞에 삽입.
- 읽기 전용으로 재사용: `assert_eq`/`assert_contains`/`assert_file`(30–55행), `REPO_DIR`(5행). 기존 agent 테스트가 frontmatter를 `sed -n '2,/^---$/p'`로 뽑는 방식(111행)을 따른다.

**Interfaces:**
- Consumes: Task 1–2가 만든 출력 필드 이름(`QUOTA_STATUS`, `ERROR_KIND`, `LIMIT_n_WINDOW`, `LIMIT_n_REMAINING`, `LIMIT_n_USED_PERCENT`, `LIMIT_n_RESET_AT`, `PROVIDER_CODE`)과 ERROR_KIND 값.
- Produces: `skills/quota/SKILL.md`(plugin 이름과 합쳐 `glm-agent:quota`), `tests/test_plugin.sh`의 변수 `quota_skill`, `skill_frontmatter`, `skill_body`, `skill_allowed`, `skill_rule_command`.

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_plugin.sh`에서 아래 두 줄 앞에 블록을 삽입한다. Edit의 `old_string`은 이 두 줄이다.

```text
if command -v claude >/dev/null 2>&1 &&
   [[ -f "$plugin_json" && -f "$marketplace_json" &&
```

삽입할 블록(`new_string` = 이 블록 + 위 두 줄):

```bash
quota_skill="$REPO_DIR/skills/quota/SKILL.md"
assert_file 'quota skill exists' "$quota_skill"
if [[ -f "$quota_skill" ]]; then
  skill_frontmatter="$(sed -n '2,/^---$/p' "$quota_skill")"
  skill_body="$(sed '1,/^---$/d' "$quota_skill")"
  skill_allowed="$(printf '%s\n' "$skill_frontmatter" |
    sed -n 's/^allowed-tools: //p')"
  skill_rule_command="${skill_allowed#Bash(}"
  skill_rule_command="${skill_rule_command%)}"
  assert_eq 'quota skill name' 'quota' \
    "$(printf '%s\n' "$skill_frontmatter" | sed -n 's/^name: //p')"
  assert_eq 'quota skill description' \
    'Use before dispatching work to glm-agent:explorer or glm-agent:general-purpose, and before returning to GLM after a quota-exhausted fallback, to read the remaining Z.ai GLM Coding Plan quota and choose between a GLM worker and native Claude.' \
    "$(printf '%s\n' "$skill_frontmatter" | sed -n 's/^description: //p')"
  assert_eq 'quota skill allows exactly the quota command' \
    "Bash(bash \"\${CLAUDE_PLUGIN_ROOT}/glm-agent\" quota)" "$skill_allowed"
  assert_contains 'quota skill body runs the allowed command' \
    "$skill_body" "$skill_rule_command"
  for keyword in QUOTA_STATUS authentication quota-exhausted fail-open \
    'REMAINING=0' RESET_AT USED_PERCENT 'USED_PERCENT>=90' \
    'USED_PERCENT>=98' TIME_LIMIT; do
    assert_contains "quota skill decision table mentions $keyword" \
      "$skill_body" "$keyword"
  done
fi

```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_plugin.sh | grep -A1 '^not ok')
```

Expected: exit 1, 아래 한 건만 FAIL이다(나머지 14개는 `if [[ -f … ]]` 안이라 실행되지 않는다). 마지막 줄은 `# 1 test(s) failed`이다.

```text
not ok 57 - quota skill exists
  missing file: /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota/skills/quota/SKILL.md
```

- [ ] **Step 3: skill 파일 작성**

`skills/quota/SKILL.md`를 Write로 만든다. 본문은 런타임 지시이므로 영어다. 아래는 파일 전체이며, 가장 바깥 네 개의 백틱 펜스는 파일 내용이 아니다.

````markdown
---
name: quota
description: Use before dispatching work to glm-agent:explorer or glm-agent:general-purpose, and before returning to GLM after a quota-exhausted fallback, to read the remaining Z.ai GLM Coding Plan quota and choose between a GLM worker and native Claude.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/glm-agent" quota)
---

# GLM quota gate

Choose whether the next unit of work goes to a GLM worker or stays on native
Claude. Run the lookup once per dispatch decision, before choosing the
provider. Do not poll, and do not open `~/.glm/quota/response.json` unless a
lookup failure needs debugging. Never print or search for the API key.

## Run the lookup

```bash
bash "${CLAUDE_PLUGIN_ROOT}/glm-agent" quota
```

The command makes one read-only request to Z.ai and prints `KEY=VALUE` lines:
`QUOTA_STATUS` (`OK` or `INVALID`), `PLAN_LEVEL`, `LIMIT_COUNT`, then for each
limit `n` the fields `LIMIT_n_TYPE`, `LIMIT_n_WINDOW`, `LIMIT_n_TOTAL`,
`LIMIT_n_USED`, `LIMIT_n_REMAINING`, `LIMIT_n_USED_PERCENT`, and
`LIMIT_n_RESET_AT` (UTC), and finally `RESPONSE`, `ERROR_KIND`, and
`PROVIDER_CODE`. Exit status 0 means `QUOTA_STATUS=OK`, even when a window is
exhausted. Exit status 1 means `QUOTA_STATUS=INVALID`. Exit status 2 is a
usage or setup error with no `QUOTA_STATUS` line: report its stderr message to
the User and stay on native Claude, as in row 1 below. The same setup problem
(missing key, missing `jq`, malformed `ZAI_BASE_URL`) would also stop a GLM
worker.

## Decide

Read the rows from the top and follow the first one that matches.

| Row | Condition | Decision |
| --- | --- | --- |
| 1 | `QUOTA_STATUS=INVALID` and `ERROR_KIND=authentication` | Native Claude. Report the failure to the User. |
| 2 | `QUOTA_STATUS=INVALID` and `ERROR_KIND=quota-exhausted` | Native Claude. The reset time is unknown, so latch for the current orchestration session. |
| 3 | `QUOTA_STATUS=INVALID` with any other `ERROR_KIND` | GLM (fail-open). The post-failure fallback is the safety net. |
| 4 | A limit whose `LIMIT_n_TYPE` is not `TIME_LIMIT` has `REMAINING=0` | Native Claude. Latch until the latest `RESET_AT` among the exhausted limits, then query again. |
| 5 | `WINDOW=5h` with `USED_PERCENT>=90`, or `WINDOW=1w` with `USED_PERCENT>=98` | Graded: send only a small, bounded, single-turn task to GLM; send multi-turn work to native Claude. |
| 6 | Anything else | GLM. |

- Only rows 1, 2, and 4 block GLM completely.
- To latch is to skip GLM and skip further lookups until the stated condition
  ends.
- A `WINDOW` that is empty or looks like `u<unit>x<number>` is an unrecognised
  window. Only row 4 applies to it; the row 5 thresholds do not. Whichever row
  matched, also report that the window is new.
- `TIME_LIMIT` appears to be a separate MCP-usage limit (unverified). Row 4
  ignores it, but it is still printed and counted in `LIMIT_COUNT`.
- An empty value means the server did not report it. Never read an empty
  `REMAINING` as 0.

## Report

State the decision in one short block: the matching row, and for each limit
that drove it `WINDOW`, `REMAINING`, and `RESET_AT` (plus `USED_PERCENT` for
row 5). For a failed lookup report `ERROR_KIND` and `PROVIDER_CODE`.

This skill only decides. Dispatch to `glm-agent:explorer` or
`glm-agent:general-purpose`, or stay on native Claude, as the decision says.
The bridge agents are unchanged: a GLM turn that later fails with
`ERROR_KIND=quota-exhausted` still returns `FALLBACK_RECOMMENDED=true`.
````

- [ ] **Step 4: 테스트가 통과하는지 확인**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_plugin.sh | tail -2)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash -n tests/test_plugin.sh && shellcheck tests/test_plugin.sh)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && claude plugin validate --strict . | tail -1)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && git check-ignore -v skills/quota/SKILL.md; echo "check-ignore exit: $?")
```

Expected:

```text
1..72
# all 72 tests passed
```

`bash -n`/`shellcheck`는 출력 없이 exit 0이다. `claude plugin validate`의 마지막 줄은 `✔ Validation passed`이다. `git check-ignore`는 아무것도 출력하지 않고 `check-ignore exit: 1`이다(`skills/`가 ignore되지 않는다).

- [ ] **Step 5: 커밋**

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && git add skills/quota/SKILL.md tests/test_plugin.sh && git commit -m "$(cat <<'EOF'
feat: add quota gate skill

Claude-Session: https://claude.ai/code/session_012m3Tn7s4e1LsFVkk4p5xPV
EOF
)")
```

---

### Task 4: `--help`, README, AGENTS.md 동기화

`--help`의 USAGE·COMMANDS(`Output:` 목록, `start` 항목과 같은 형식)·SECURITY·EXIT STATUS, README(Commands 표, "Quota gate" 절, Security 문단), AGENTS.md를 구현과 맞춘다. README의 예시 출력이 실제 CLI 출력과 같은지 테스트가 비교한다.

**Files:**
- Modify: `glm-agent` — `usage()` heredoc: USAGE의 `glm-agent close <worker-id>`(44행) 다음, COMMANDS의 `close` 항목 끝(128행)과 `WORKER FILES`(130행) 사이, SECURITY 끝(183행)과 `EXIT STATUS`(185행) 사이, EXIT STATUS의 0·1행(186–187행).
- Modify: `README.md` — Commands 표의 `close` 행(180행) 다음, `## Security`(279행) 바로 앞에 "Quota gate" 절, Security 마지막 문단(292행) 뒤.
- Modify: `AGENTS.md` — Repository layout(24–27행)과 Behavioral invariants(`API keys and Claude session IDs…` 줄, 약 44행 이후). `CLAUDE.md`는 symlink이므로 건드리지 않는다.
- Test: `tests/test_glm_agent.sh` — 428행 `assert_eq 'version is available' …` 바로 앞에 help 검사 삽입, 마지막 `printf '1..%d\n' "$tests"` 앞에 README 예시 비교 삽입. `tests/test_plugin.sh` — 86–87행 README 검사 뒤에 삽입.

**Interfaces:**
- Consumes: `help_output`(405행, `"$($SCRIPT --help)"`), `expected_quota_ok`(Task 1), `readme`(62행, README 전문), `REPO_DIR`.
- Produces: help 텍스트의 고정 문구(`glm-agent quota`, `QUOTA_STATUS=OK|INVALID`, `LIMIT_<i>_WINDOW=<n>h|<n>w|u<unit>x<number>`, `quota exits 0 for QUOTA_STATUS=OK`, `quota exits 1 when the lookup failed`, `HTTP header that curl reads from`), README의 "Quota gate" 절과 예시 코드 블록(`QUOTA_STATUS=OK`로 시작해 `PROVIDER_CODE=`로 끝남).

- [ ] **Step 1: 실패하는 테스트 작성**

(1a) `tests/test_glm_agent.sh`에서 아래 한 줄을 앵커로, 그 앞에 help 검사를 삽입한다. `old_string`:

```text
assert_eq 'version is available' 'glm-agent 0.4.0' "$($SCRIPT --version)"
```

`new_string` = 아래 블록 + 위 한 줄:

```bash
assert_contains 'help lists quota in the usage synopsis' "$help_output" \
  $'\n  glm-agent quota\n'
assert_contains 'help documents the quota command' "$help_output" \
  $'\n    quota\n'
assert_contains 'help documents quota status values' "$help_output" \
  'QUOTA_STATUS=OK|INVALID'
assert_contains 'help documents the quota window format' "$help_output" \
  'LIMIT_<i>_WINDOW=<n>h|<n>w|u<unit>x<number>'
for quota_field in 'PLAN_LEVEL=' 'LIMIT_COUNT=' 'LIMIT_<i>_TYPE=' \
  'LIMIT_<i>_TOTAL=' 'LIMIT_<i>_USED=' 'LIMIT_<i>_REMAINING=' \
  'LIMIT_<i>_USED_PERCENT=' 'LIMIT_<i>_RESET_AT='; do
  assert_contains "help documents quota field $quota_field" "$help_output" \
    "$quota_field"
done
assert_contains 'help documents the quota success exit' "$help_output" \
  'quota exits 0 for QUOTA_STATUS=OK'
assert_contains 'help documents the quota failure exit' "$help_output" \
  'quota exits 1 when the lookup failed'
assert_contains 'help documents the quota stdin header' "$help_output" \
  'HTTP header that curl reads from'
```

(1b) 같은 파일의 `printf '1..%d\n' "$tests"` 줄 바로 앞(Task 2 블록 뒤)에 삽입한다.

```bash
# --- quota: README example matches the CLI output ----------------------------
readme_quota_example="$(sed -n '/^QUOTA_STATUS=OK$/,/^PROVIDER_CODE=$/p' \
  "$REPO_DIR/README.md" | sed '/^RESPONSE=/d')"
actual_quota_example="$(printf '%s\n' "$expected_quota_ok" |
  sed '/^RESPONSE=/d')"
assert_eq 'README quota example matches the CLI output' \
  "$actual_quota_example" "$readme_quota_example"

```

(1c) `tests/test_plugin.sh`에서 아래 두 줄 뒤에 검사를 삽입한다. `old_string`:

```text
assert_contains 'README distinguishes parent stop from cancel' "$readme" \
  'Stopping the parent Claude Code turn does not cancel'
```

`new_string` = 위 두 줄 + 아래 블록:

```bash
assert_contains 'README documents the quota command' "$readme" \
  'glm-agent quota'
assert_contains 'README documents the quota skill' "$readme" \
  'glm-agent:quota'
assert_contains 'README documents the 5-hour threshold' "$readme" \
  'USED_PERCENT>=90'
assert_contains 'README documents the weekly threshold' "$readme" \
  'USED_PERCENT>=98'
assert_contains 'README documents quota fail-open' "$readme" 'fail-open'
assert_contains 'README documents the stdin header' "$readme" \
  'curl -H @-'
assert_contains 'AGENTS.md lists the skills directory' \
  "$(cat "$REPO_DIR/AGENTS.md")" 'skills/quota/SKILL.md'
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_glm_agent.sh | grep '^not ok')
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_plugin.sh | grep '^not ok')
```

Expected: 첫 명령은 16건(`not ok 14 - help lists quota in the usage synopsis`부터 help 15건, 마지막에 `not ok 503 - README quota example matches the CLI output`)을 출력하고, 둘째 명령은 7건(`not ok 16 - README documents the quota command`부터 `not ok 22 - AGENTS.md lists the skills directory`)을 출력한다. 각 실행의 stderr 마지막 줄은 `# 16 test(s) failed`, `# 7 test(s) failed`이다.

- [ ] **Step 3: 문서 구현**

`glm-agent`에서 네 번 Edit를 한다.

(3a) USAGE. `old_string`:

```text
  glm-agent close <worker-id>
  glm-agent --help
```

`new_string`:

```text
  glm-agent close <worker-id>
  glm-agent quota
  glm-agent --help
```

(3b) COMMANDS. `old_string`:

```text
    worker remains available to result and status but rejects send and tui.

WORKER FILES
```

`new_string`:

```text
    worker remains available to result and status but rejects send and tui.

    quota
        Query Z.ai's monitor API once and print the credit quota per window.
        This creates no worker and starts no Claude session. Values are
        printed as the server reports them; the glm-agent:quota skill turns
        them into a dispatch decision. The last raw response and curl stderr
        are kept in ~/.glm/quota/response.json and ~/.glm/quota/stderr.log.
        Requires curl 7.55 or newer and jq.

        Output:
          QUOTA_STATUS=OK|INVALID
          PLAN_LEVEL=<plan-or-empty>
          LIMIT_COUNT=<n>
          LIMIT_<i>_TYPE=<server-type>
          LIMIT_<i>_WINDOW=<n>h|<n>w|u<unit>x<number>
          LIMIT_<i>_TOTAL=<credits-or-empty>
          LIMIT_<i>_USED=<credits-or-empty>
          LIMIT_<i>_REMAINING=<credits-or-empty>
          LIMIT_<i>_USED_PERCENT=<percent-or-empty>
          LIMIT_<i>_RESET_AT=<UTC-timestamp-or-empty>
          RESPONSE=<absolute-path>
          ERROR_KIND=<classification-or-empty>
          PROVIDER_CODE=<Z.ai-code-or-empty>

        The LIMIT_<i>_ lines appear once per limit, only when
        QUOTA_STATUS=OK. A failed lookup prints only QUOTA_STATUS=INVALID,
        RESPONSE, ERROR_KIND, and PROVIDER_CODE. ERROR_KIND is one of
        authentication, quota-exhausted, provider-transient,
        model-unavailable, provider-error, or invalid-response.

WORKER FILES
```

(3c) SECURITY와 EXIT STATUS(의미는 그대로, quota 사용처만 덧붙인다). `old_string`:

```text
  approval prompt. Start workers only in repositories you trust.

EXIT STATUS
  0  Command succeeded; DONE and BLOCKED are both successful worker turns.
  1  Claude invocation or worker result protocol failed (STATUS=INVALID).
  2  Invalid CLI usage, configuration, dependency, or worker state.
```

`new_string`:

```text
  approval prompt. Start workers only in repositories you trust.

  quota sends the API key to Z.ai only as an HTTP header that curl reads from
  stdin, so the key never appears in a process argument list. ~/.glm/quota/
  holds the raw response body and curl stderr, never the key.

EXIT STATUS
  0  Command succeeded; DONE and BLOCKED are both successful worker turns.
     quota exits 0 for QUOTA_STATUS=OK, even when a window is exhausted.
  1  Claude invocation or worker result protocol failed (STATUS=INVALID).
     quota exits 1 when the lookup failed (QUOTA_STATUS=INVALID).
  2  Invalid CLI usage, configuration, dependency, or worker state.
```

`README.md`에서 세 번 Edit를 한다.

(3d) Commands 표. `old_string`:

```text
| `close <worker-id>` | Prevent further sends while preserving all worker files. |
```

`new_string`:

```text
| `close <worker-id>` | Prevent further sends while preserving all worker files. |
| `quota` | Print the Z.ai credit quota per window; creates no worker and starts no Claude session. |
```

(3e) "Quota gate" 절. `old_string`:

```text
## Security

`start` and `send` invoke Claude Code with
```

`new_string`(가장 바깥 네 개의 백틱 펜스는 내용이 아니다):

````markdown
## Quota gate

`glm-agent quota` makes one read-only request to Z.ai's monitor API and prints
the credit quota per window. It needs `curl` 7.55 or newer and `jq`, creates no
worker, and starts no Claude session.

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
RESPONSE=/home/you/.glm/quota/response.json
ERROR_KIND=
PROVIDER_CODE=
```

- The numbers are the server's own; the CLI computes no thresholds.
  `RESET_AT` is UTC, and an empty value means the server did not report it.
- `WINDOW` is `<n>h` for unit 3 and `<n>w` for unit 6. Any other unit prints
  as `u<unit>x<number>`. The unit codes are inferred from observed responses;
  Z.ai does not document them.
- Exit status 0 means the lookup succeeded, even when `REMAINING` is 0. Exit
  status 1 prints only `QUOTA_STATUS=INVALID`, `RESPONSE`, `ERROR_KIND`
  (`authentication`, `quota-exhausted`, `provider-transient`,
  `model-unavailable`, `provider-error`, or `invalid-response`), and
  `PROVIDER_CODE`. Exit status 2 is a usage or setup error.
- `~/.glm/quota/response.json` and `~/.glm/quota/stderr.log` keep the last
  call only.

The plugin ships the `glm-agent:quota` skill. An orchestrator runs it before
dispatching to `glm-agent:explorer` or `glm-agent:general-purpose`:

- Setup errors (exit status 2), `authentication` and `quota-exhausted`
  failures, and any non-`TIME_LIMIT` limit with `REMAINING=0` send the work to
  native Claude.
- `USED_PERCENT>=90` on the 5-hour window or `USED_PERCENT>=98` on the weekly
  window allows only small, bounded, single-turn tasks on GLM.
- Any other lookup failure proceeds with GLM (fail-open); the existing
  `quota-exhausted` fallback remains the safety net.

The thresholds live in the skill, not in the CLI.

## Security

`start` and `send` invoke Claude Code with
````

(3f) Security 문단. `old_string`:

```text
that may contain private task data.

## Development
```

`new_string`:

```text
that may contain private task data.

`quota` passes the API key to `curl` as a header read from stdin
(`curl -H @-`), so the key never appears in a process argument list.
`~/.glm/quota/` stores only the response body and curl's stderr.

## Development
```

`AGENTS.md`에서 두 번 Edit를 한다.

(3g) Repository layout. `old_string`:

```text
- `agents/`: thin Claude Code bridges for explorer and general-purpose workers.
- `scripts/bump-version.sh`: synchronized CLI/plugin/marketplace version bump.
- `tests/test_glm_agent.sh`: hermetic CLI tests using a fake `claude` binary.
- `tests/test_plugin.sh`: plugin schema, bridge contract, and version tests.
```

`new_string`:

```text
- `agents/`: thin Claude Code bridges for explorer and general-purpose workers.
- `skills/`: Claude Code skills; `skills/quota/SKILL.md` is the quota gate that
  runs before work is dispatched to GLM or native Claude.
- `scripts/bump-version.sh`: synchronized CLI/plugin/marketplace version bump.
- `tests/test_glm_agent.sh`: hermetic CLI tests using fake `claude` and `curl`
  binaries.
- `tests/test_plugin.sh`: plugin schema, bridge contract, skill contract, and
  version tests.
```

(3h) Behavioral invariants. `old_string`:

```text
- API keys and Claude session IDs must not appear in normal stdout.
```

`new_string`:

```text
- API keys and Claude session IDs must not appear in normal stdout.
- `quota` passes the API key to `curl` only as a stdin header (`-H @-`); it
  never appears in argv, stdout, stderr, or files.
```

- [ ] **Step 4: 테스트가 통과하는지 확인**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_glm_agent.sh | tail -2)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_plugin.sh | tail -2)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash -n glm-agent tests/test_glm_agent.sh tests/test_plugin.sh && shellcheck glm-agent tests/test_glm_agent.sh tests/test_plugin.sh)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash glm-agent --help | sed -n '/^    quota$/,/^WORKER FILES$/p' | head -12)
```

Expected: 처음 두 명령은 각각 `1..503` / `# all 503 tests passed`, `1..79` / `# all 79 tests passed`이다. `bash -n`/`shellcheck`는 출력 없이 exit 0이다. 마지막 명령은 `    quota`로 시작하는 COMMANDS 항목을 `Requires curl 7.55 or newer and jq.` 줄까지 보여 준다. `git diff -- AGENTS.md`로 `CLAUDE.md`가 아니라 `AGENTS.md`만 바뀐 것도 확인한다.

- [ ] **Step 5: 커밋**

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && git add glm-agent README.md AGENTS.md tests/test_glm_agent.sh tests/test_plugin.sh && git commit -m "$(cat <<'EOF'
docs: document quota command and gate skill

Claude-Session: https://claude.ai/code/session_012m3Tn7s4e1LsFVkk4p5xPV
EOF
)")
```

---

### Task 5: 버전 0.5.0, 전체 검증, live smoke test

버전은 `scripts/bump-version.sh`로만 올린다. 기존 테스트 두 곳이 `0.4.0`을 못박고 있으므로 먼저 기대값을 0.5.0으로 바꿔 실패를 확인한다. 그 뒤 AGENTS.md Testing 절의 검증 목록을 전부 실행하고 최종 diff를 검토한다. 실제 Z.ai 호출은 User 허가 후에만 한다.

**Files:**
- Modify (스크립트가 갱신): `glm-agent`(5행 `VERSION="0.4.0"`), `.claude-plugin/plugin.json`(3행), `.claude-plugin/marketplace.json`(11행). 직접 편집하지 않는다.
- Test: `tests/test_glm_agent.sh`(Task 4 이후 약 448행의 `assert_eq 'version is available' …`), `tests/test_plugin.sh`(Task 4 이후 약 120행의 `assert_eq 'release version is 0.4.0' …`; HEAD에서는 107행).

**Interfaces:**
- Consumes: `scripts/bump-version.sh <major.minor.patch>`(성공 시 `VERSION=<version>` 출력), 기존 parity 테스트(CLI·plugin·marketplace 버전 일치).
- Produces: 세 파일의 버전이 모두 `0.5.0`인 상태, 커밋 하나.

- [ ] **Step 1: 버전 기대값을 0.5.0으로 바꾸는 테스트 수정**

`tests/test_glm_agent.sh` Edit. `old_string`:

```text
assert_eq 'version is available' 'glm-agent 0.4.0' "$($SCRIPT --version)"
```

`new_string`:

```text
assert_eq 'version is available' 'glm-agent 0.5.0' "$($SCRIPT --version)"
```

`tests/test_plugin.sh` Edit. `old_string`:

```text
  assert_eq 'release version is 0.4.0' '0.4.0' "$cli_version"
```

`new_string`:

```text
  assert_eq 'release version is 0.5.0' '0.5.0' "$cli_version"
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_glm_agent.sh | grep -A1 '^not ok')
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_plugin.sh | grep -A1 '^not ok')
```

Expected:

```text
not ok 29 - version is available
  expected [glm-agent 0.5.0], got [glm-agent 0.4.0]
```

```text
not ok 27 - release version is 0.5.0
  expected [0.5.0], got [0.4.0]
```

- [ ] **Step 3: 버전 bump**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash scripts/bump-version.sh 0.5.0)
```

Expected: `VERSION=0.5.0`, exit 0. 이어서 아래 명령이 정확히 세 줄(`glm-agent:5`, `.claude-plugin/marketplace.json:11`, `.claude-plugin/plugin.json:3`, 모두 `0.5.0`)만 출력해야 한다.

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && grep -rn '0\.[45]\.0' glm-agent .claude-plugin README.md AGENTS.md)
```

- [ ] **Step 4: AGENTS.md Testing 절의 전체 검증**

Run (각각 별도로 실행하고 결과를 확인한다):

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_glm_agent.sh | tail -2)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash tests/test_plugin.sh | tail -2)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash -n glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && shellcheck glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && claude plugin validate --strict . | tail -1)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash glm-agent --version)
```

Expected:

```text
1..503
# all 503 tests passed
```

```text
1..79
# all 79 tests passed
```

`bash -n`과 `shellcheck`는 출력 없이 exit 0이다. `claude plugin validate --strict .`의 마지막 줄은 `✔ Validation passed`이다. `--version`은 `glm-agent 0.5.0`이다. `shellcheck`가 설치돼 있지 않으면 건너뛰지 말고 그 사실을 보고한다.

- [ ] **Step 5: 최종 diff 검토**

Run:

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && git status --short)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && git diff 35a58e3 --stat -- . ':!superpowers')
```

확인할 것:

- 변경 파일이 `AGENTS.md`, `README.md`, `glm-agent`, `skills/quota/SKILL.md`, `tests/test_glm_agent.sh`, `tests/test_plugin.sh`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` 여덟 개뿐이다(`CLAUDE.md`는 symlink 그대로).
- `git diff 35a58e3 -- glm-agent`에 key를 argv에 넣는 곳이 없고(`curl` 호출은 Global Constraints의 한 곳뿐), `quota_render_jq`의 jq 식과 `--help`가 서로 같은 필드 이름을 쓴다.
- README 예시 출력은 `README quota example matches the CLI output` 테스트가 실제 출력과 비교한다. `--help`의 Output 목록과 README 필드 이름이 일치하는지 눈으로 한 번 더 본다.

- [ ] **Step 6: 커밋**

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && git add glm-agent .claude-plugin/plugin.json .claude-plugin/marketplace.json tests/test_glm_agent.sh tests/test_plugin.sh && git commit -m "$(cat <<'EOF'
release: prepare glm-agent 0.5.0

Claude-Session: https://claude.ai/code/session_012m3Tn7s4e1LsFVkk4p5xPV
EOF
)")
```

- [ ] **Step 7: live Z.ai smoke test — User 허가 후에만 실행**

이 단계는 실제 네트워크 호출이다. probe 때의 허가와 별개로, 실행 직전에 User에게 허가를 다시 받는다. 허가가 없으면 실행하지 않고 "smoke test 미실행"이라고 보고한다. key는 CLI가 `~/.glm/.env.auth`에서 읽는다. key를 출력하거나 열람하지 않는다(`cat ~/.glm/.env.auth`, `env | grep ZAI` 금지).

```bash
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && bash glm-agent quota; echo "exit: $?")
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && jq -c 'keys' ~/.glm/quota/response.json)
(cd /Users/h_kang/dev/git/powdream/glm-agent/.worktrees/glm-quota && ls -ld ~/.glm ~/.glm/quota && ls -l ~/.glm/quota)
```

Expected:

- 첫 명령: `QUOTA_STATUS=OK`로 시작하고 `PLAN_LEVEL=…`, `LIMIT_COUNT=<n>`, 각 `LIMIT_<i>_*` 줄, `RESPONSE=/Users/h_kang/.glm/quota/response.json`, 빈 `ERROR_KIND=`/`PROVIDER_CODE=`가 이어지고 `exit: 0`이다. 값은 계정 현황에 따라 달라진다. `LIMIT_<i>_WINDOW`가 `5h`/`1w`가 아닌 `u<unit>x<number>`로 나오면 spec 11절 "열린 질문"(unit 코드표)에 해당하는 새 정보이므로 그대로 User에게 보고한다. `QUOTA_STATUS=INVALID`면 `ERROR_KIND`와 `PROVIDER_CODE`를 보고하고 멈춘다(재시도 반복 금지).
- 둘째 명령: probe에서 관측한 최상위 키 `["code","data","msg","success"]`(순서는 jq가 정렬한 그대로)이다.
- 셋째 명령: `~/.glm`과 `~/.glm/quota`는 `drwx------`, `response.json`과 `stderr.log`는 `-rw-------`이고 숨김 temp 파일(`.response.*`, `.stderr.*`)이 남아 있지 않다.

이 단계는 커밋하지 않는다. 결과(출력 필드, exit status)만 User에게 보고하고, push·merge·재설치는 별도 승인을 받는다.
