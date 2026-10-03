#!/usr/bin/env bash

dd_fetch_quota() {
  DD_Q_RC=0
  DD_Q_TEXT="$(dd_cli quota 2>/dev/null)" || DD_Q_RC=$?
}

dd_is_number() {
  [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

dd_number_test() {
  awk -v a="$1" -v op="$2" -v b="$3" 'BEGIN {
    a += 0
    b += 0
    if (op == "<=") r = (a <= b)
    else if (op == "<") r = (a < b)
    else r = (a >= b)
    exit !r
  }'
}

dd_limit_get() {
  dd_kv_get "$DD_Q_TEXT" "LIMIT_$1_$2"
}

dd_pick_reset() {
  local line value latest=""
  while IFS= read -r line; do
    [[ "$line" == r:* ]] || continue
    value="${line#r:}"
    if [[ ! "$value" =~ ^[0-9A-Za-z:.+-]+$ ]]; then
      printf 'session\n'
      return 0
    fi
    if [[ "$value" > "$latest" ]]; then
      latest="$value"
    fi
  done <<<"$1"
  printf '%s\n' "$latest"
}

dd_emit_blocked() {
  printf 'GLM_BLOCKED row=%s reset_at=%s scope=%s\n' "$1" "$2" "$DD_QUOTA_SCOPE"
  return 10
}

dd_note_used() {
  local window="$1" used="$2"
  if ! dd_is_number "$used"; then
    return 0
  fi
  if [[ "$window" == 5h && "$DD_QUOTA_5H_USED" == unknown ]]; then
    DD_QUOTA_5H_USED="$used"
  fi
  if [[ "$window" == 1w && "$DD_QUOTA_1W_USED" == unknown ]]; then
    DD_QUOTA_1W_USED="$used"
  fi
}

dd_gate_quota() {
  local status scope error_kind i type window remaining percent reset
  local exhausted="" short="" graded="" threshold=""
  export DD_QUOTA_SCOPE="unknown" DD_QUOTA_5H_USED="unknown" DD_QUOTA_1W_USED="unknown"
  dd_fetch_quota
  if [[ "$DD_Q_RC" != 0 && "$DD_Q_RC" != 1 ]] || ! dd_kv_has "$DD_Q_TEXT" QUOTA_STATUS; then
    dd_emit_blocked 1 session || return $?
  fi
  scope="$(dd_kv_get "$DD_Q_TEXT" SCOPE)"
  if [[ "$scope" =~ ^[A-Za-z0-9._-]+$ ]]; then
    DD_QUOTA_SCOPE="$scope"
  fi
  status="$(dd_kv_get "$DD_Q_TEXT" QUOTA_STATUS)"
  if [[ "$status" == INVALID ]]; then
    error_kind="$(dd_kv_get "$DD_Q_TEXT" ERROR_KIND)"
    case "$error_kind" in
      authentication) dd_emit_blocked 1 session || return $? ;;
      quota-exhausted) dd_emit_blocked 2 session || return $? ;;
    esac
    DD_QUOTA_SCOPE="unknown"
    return 0
  fi
  if [[ "$status" != OK ]]; then
    dd_emit_blocked 1 session || return $?
  fi
  if [[ -n "$DD_EST_CREDITS" ]]; then
    threshold=$((2 * 10#$DD_EST_CREDITS))
  fi
  i=1
  while dd_kv_has "$DD_Q_TEXT" "LIMIT_${i}_TYPE"; do
    type="$(dd_limit_get "$i" TYPE)"
    window="$(dd_limit_get "$i" WINDOW)"
    remaining="$(dd_limit_get "$i" REMAINING)"
    percent="$(dd_limit_get "$i" USED_PERCENT)"
    reset="$(dd_limit_get "$i" RESET_AT)"
    dd_note_used "$window" "$(dd_limit_get "$i" USED)"
    if [[ "$type" != TIME_LIMIT ]] && dd_is_number "$remaining" &&
       dd_number_test "$remaining" "<=" 0; then
      exhausted+="r:$reset"$'\n'
    fi
    if [[ -n "$threshold" && ( "$window" == 5h || "$window" == 1w ) ]] &&
       dd_is_number "$remaining" && dd_number_test "$remaining" "<" "$threshold"; then
      short+="r:$reset"$'\n'
    fi
    if dd_is_number "$percent"; then
      if [[ "$window" == 5h ]] && dd_number_test "$percent" ">=" 90; then
        graded+="r:$reset"$'\n'
      fi
      if [[ "$window" == 1w ]] && dd_number_test "$percent" ">=" 98; then
        graded+="r:$reset"$'\n'
      fi
    fi
    i=$((i + 1))
  done
  if [[ -n "$exhausted" ]]; then
    dd_emit_blocked 4 "$(dd_pick_reset "$exhausted")" || return $?
  fi
  if [[ -n "$short" ]]; then
    dd_emit_blocked 7 "$(dd_pick_reset "$short")" || return $?
  fi
  if [[ -n "$graded" && "$DD_SMALL" != true ]]; then
    dd_emit_blocked 5 "$(dd_pick_reset "$graded")" || return $?
  fi
  return 0
}

dd_read_quota_1w_used() {
  export DD_QUOTA_SCOPE="unknown" DD_QUOTA_5H_USED="unknown" DD_QUOTA_1W_USED="unknown"
  local i=1
  dd_fetch_quota
  if [[ "$(dd_kv_get "$DD_Q_TEXT" QUOTA_STATUS)" == OK ]]; then
    while dd_kv_has "$DD_Q_TEXT" "LIMIT_${i}_TYPE"; do
      dd_note_used "$(dd_limit_get "$i" WINDOW)" "$(dd_limit_get "$i" USED)"
      i=$((i + 1))
    done
  fi
  printf '%s\n' "$DD_QUOTA_1W_USED"
}
