#!/usr/bin/env bash

dd_emit_still_running() {
  printf 'GLM_STILL_RUNNING label=%s worker=%s waited_seconds=%s\n' "$1" "$2" "$3"
  return 13
}

dd_wait_terminal() {
  local label="$1" worker="$2" started elapsed timeout remaining out result
  started="$(date +%s)"
  while :; do
    elapsed=$(($(date +%s) - started))
    if ((elapsed >= DD_MAX_WAIT)); then
      dd_emit_still_running "$label" "$worker" "$elapsed" || return $?
    fi
    remaining=$((DD_MAX_WAIT - elapsed))
    timeout="$DD_POLL"
    if ((remaining < timeout)); then
      timeout="$remaining"
    fi
    out="$(dd_cli wait --timeout "$timeout" "$worker" 2>/dev/null)" || true
    result="$(dd_kv_get "$out" WAIT_RESULT)"
    case "$result" in
      TERMINAL) return 0 ;;
      TIMEOUT) ;;
      *) sleep "$DD_POLL" ;;
    esac
  done
}

dd_extract_section() {
  awk -v title="$2" '
    { line[NR] = $0 }
    END {
      last = NR
      if (last > 0 && line[last] ~ /^STATUS: /) last--
      on = 0
      out = 0
      for (i = 1; i <= last; i++) {
        if (line[i] == "# " title) { on = 1; continue }
        if (on && line[i] ~ /^# /) break
        if (on) {
          out++
          if (out > 20) { print "... (truncated)"; break }
          print line[i]
        }
      }
    }' "$1"
}

dd_emit_result_sections() {
  if [[ ! -f "$1" ]]; then
    return 0
  fi
  printf -- '--- Summary ---\n'
  dd_extract_section "$1" Summary
  printf -- '--- Remaining Issues ---\n'
  dd_extract_section "$1" "Remaining Issues"
}

dd_format_delta() {
  if ! dd_is_number "$1" || ! dd_is_number "$2"; then
    printf 'unknown\n'
    return 0
  fi
  awk -v before="$1" -v after="$2" 'BEGIN {
    d = after - before
    if (d > 0) printf "+%s\n", d
    else if (d < 0) printf "%s\n", d
    else printf "0\n"
  }'
}

dd_emit_verdict() {
  local label="$1" worker="$2" out status class result fallback delta
  out="$(dd_cli status "$worker" 2>/dev/null)" || true
  status="$(dd_kv_get "$out" STATUS)"
  case "$status" in
    DONE|BLOCKED|INVALID) ;;
    *) status=INVALID ;;
  esac
  class="$(dd_kv_get "$out" ERROR_KIND)"
  if [[ ! "$class" =~ ^[A-Za-z0-9._-]+$ ]]; then
    class=-
  fi
  result="$(dd_kv_get "$out" RESULT)"
  fallback="$(dd_kv_get "$out" FALLBACK_RECOMMENDED)"
  if [[ "$fallback" != true ]]; then
    fallback=false
  fi
  delta="$(dd_format_delta "$(dd_registry_get "$DD_SESSION" "$label" quota_1w_used)" "$(dd_read_quota_1w_used)")"
  printf 'GLM_VERDICT label=%s worker=%s status=%s class=%s result=%s files_changed=%s quota_1w_delta=%s fallback=%s\n' \
    "$label" "$worker" "$status" "$class" "$(dd_encode_token "${result:--}")" na "$delta" "$fallback"
  dd_emit_result_sections "$result"
  [[ "$status" == DONE ]]
}

dd_judge() {
  dd_wait_terminal "$1" "$2" || return $?
  dd_emit_verdict "$1" "$2"
}
