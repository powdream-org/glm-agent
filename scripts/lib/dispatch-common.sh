#!/usr/bin/env bash
DD_USAGE='usage: glm-dispatch <subcommand> --session <id> [options]
subcommands: run send attach pending ack status result cancel close
common options: --session <id> (required), --label <name> (all but pending)
run: --role explorer|general-purpose --model haiku|sonnet|opus --cwd <dir>
     --task-file <path> [--wait] [--max-wait <s>] [--stall-timeout <s>]
     [--poll-seconds <s>] [--small] [--est-credits <n>] [--allow-path <glob>]...
send: --task-file <path> [--wait] [--max-wait <s>] [--stall-timeout <s>]
      [--poll-seconds <s>] [--allow-path <glob>]...
attach: [--max-wait <s>] [--stall-timeout <s>] [--poll-seconds <s>]
pending: --session <id> only
ack, status, result, cancel, close: --session <id> --label <name>'

dd_print_usage() {
  printf '%s\n' "$DD_USAGE" >&2
}

dd_fail() {
  printf 'glm-dispatch: %s\n' "$1" >&2
  exit 2
}

dd_state_home() {
  printf '%s\n' "${GLM_AGENT_HOME:-$HOME/.glm}"
}

dd_now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

dd_cli() {
  "$DD_CLI" "$@"
}

dd_kv_has() {
  [[ $'\n'"$1" == *$'\n'"$2="* ]]
}

dd_kv_get() {
  printf '%s\n' "$1" | sed -n "/^$2=/{s/^$2=//p;q;}"
}

dd_kv_get_file() {
  sed -n "/^$2=/{s/^$2=//p;q;}" "$1"
}

dd_encode_token() {
  printf '%s\n' "${1// /%20}"
}

dd_decode_token() {
  printf '%s\n' "${1//\%20/ }"
}

dd_read_file_exact() {
  DD_FILE_CONTENT="$(cat "$1"; printf x)"
  DD_FILE_CONTENT="${DD_FILE_CONTENT%x}"
}

dd_read_brief() {
  dd_read_file_exact "$1"
  if [[ "$DD_FILE_CONTENT" == -* ]]; then
    DD_FILE_CONTENT=$'\n'"$DD_FILE_CONTENT"
  fi
}

dd_init_options() {
  export DD_SESSION=""
  export DD_LABEL=""
  export DD_ROLE=""
  export DD_MODEL=""
  export DD_CWD=""
  export DD_TASK_FILE=""
  export DD_WAIT=false
  export DD_MAX_WAIT=7000
  export DD_STALL_TIMEOUT=300
  export DD_POLL=20
  export DD_SMALL=false
  export DD_EST_CREDITS=""
  DD_ALLOW_PATHS=()
}

dd_parse_options() {
  local allowed=" $1 " opt
  shift
  while (($# > 0)); do
    opt="$1"
    [[ "$opt" == --* ]] || dd_fail "unexpected argument: $opt"
    [[ "$allowed" == *" $opt "* ]] || dd_fail "unknown option: $opt"
    case "$opt" in
      --wait)
        DD_WAIT=true
        shift
        continue
        ;;
      --small)
        DD_SMALL=true
        shift
        continue
        ;;
    esac
    (($# >= 2)) || dd_fail "$opt requires a value"
    case "$opt" in
      --session) DD_SESSION="$2" ;;
      --label) DD_LABEL="$2" ;;
      --role) DD_ROLE="$2" ;;
      --model) DD_MODEL="$2" ;;
      --cwd) DD_CWD="$2" ;;
      --task-file) DD_TASK_FILE="$2" ;;
      --max-wait) DD_MAX_WAIT="$2" ;;
      --stall-timeout) DD_STALL_TIMEOUT="$2" ;;
      --poll-seconds) DD_POLL="$2" ;;
      --est-credits) DD_EST_CREDITS="$2" ;;
      --allow-path) DD_ALLOW_PATHS+=("$2") ;;
    esac
    shift 2
  done
}

dd_check_integer() {
  local name="$1" value="$2" min="$3" max="$4"
  if [[ ! "$value" =~ ^[0-9]{1,9}$ ]] || ((10#$value < min || 10#$value > max)); then
    dd_fail "$name must be an integer from $min to $max"
  fi
}

dd_validate_task_file() {
  local size
  [[ -n "$DD_TASK_FILE" ]] || dd_fail "--task-file is required"
  [[ -f "$DD_TASK_FILE" && -r "$DD_TASK_FILE" ]] ||
    dd_fail "task file is not readable: $DD_TASK_FILE"
  [[ -s "$DD_TASK_FILE" ]] || dd_fail "task file is empty: $DD_TASK_FILE"
  size="$(wc -c <"$DD_TASK_FILE" | tr -d ' ')"
  ((size <= 262144)) || dd_fail "task-file too large (max 262144 bytes)"
}

dd_validate_numbers() {
  dd_check_integer --max-wait "$DD_MAX_WAIT" 1 999999999
  dd_check_integer --stall-timeout "$DD_STALL_TIMEOUT" 0 999999999
  dd_check_integer --poll-seconds "$DD_POLL" 1 300
}

dd_validate_run_options() {
  [[ -n "$DD_ROLE" ]] || dd_fail "--role is required"
  case "$DD_ROLE" in
    explorer|general-purpose) ;;
    *) dd_fail "--role must be explorer or general-purpose" ;;
  esac
  [[ -n "$DD_MODEL" ]] || dd_fail "--model is required"
  case "$DD_MODEL" in
    haiku|sonnet|opus) ;;
    *) dd_fail "--model must be haiku, sonnet, or opus" ;;
  esac
  [[ -n "$DD_CWD" ]] || dd_fail "--cwd is required"
  [[ -d "$DD_CWD" ]] || dd_fail "--cwd is not a directory: $DD_CWD"
  DD_CWD="$(cd "$DD_CWD" && pwd -P)"
  if [[ -n "$DD_EST_CREDITS" ]]; then
    dd_check_integer --est-credits "$DD_EST_CREDITS" 1 999999999
  fi
}

dd_validate_options() {
  local cmd="$1"
  [[ -n "$DD_SESSION" ]] || dd_fail "--session is required"
  if [[ ! "$DD_SESSION" =~ ^[A-Za-z0-9._-]+$ || "$DD_SESSION" == . || "$DD_SESSION" == .. ]]; then
    dd_fail "--session must match ^[A-Za-z0-9._-]+\$"
  fi
  if [[ "$cmd" == pending ]]; then
    return 0
  fi
  [[ -n "$DD_LABEL" ]] || dd_fail "--label is required"
  if [[ ! "$DD_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    dd_fail "--label must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\$"
  fi
  case "$cmd" in
    run)
      dd_validate_run_options
      dd_validate_task_file
      dd_validate_numbers
      ;;
    send)
      dd_validate_task_file
      dd_validate_numbers
      ;;
    attach)
      dd_validate_numbers
      ;;
  esac
}

dd_main() {
  local cmd="${1:-}" allowed
  if [[ -z "$cmd" ]]; then
    dd_print_usage
    exit 2
  fi
  shift
  case "$cmd" in
    -h|--help|help)
      dd_print_usage
      exit 2
      ;;
    run)
      allowed="--session --label --role --model --cwd --task-file --wait --max-wait --stall-timeout --poll-seconds --small --est-credits --allow-path"
      ;;
    send)
      allowed="--session --label --task-file --wait --max-wait --stall-timeout --poll-seconds --allow-path"
      ;;
    attach)
      allowed="--session --label --max-wait --stall-timeout --poll-seconds"
      ;;
    pending)
      allowed="--session"
      ;;
    ack|status|result|cancel|close)
      allowed="--session --label"
      ;;
    *)
      dd_print_usage
      exit 2
      ;;
  esac
  dd_init_options
  if [[ "$cmd" == attach ]]; then
    DD_WAIT=true
  fi
  dd_parse_options "$allowed" "$@"
  dd_validate_options "$cmd"
  declare -F "dd_cmd_$cmd" >/dev/null || dd_fail "subcommand is not available: $cmd"
  "dd_cmd_$cmd"
}

dd_count_allow_paths() {
  printf '%s\n' "${#DD_ALLOW_PATHS[@]}"
}
