#!/usr/bin/env bash

dd_emit_still_running() {
  printf 'GLM_STILL_RUNNING label=%s worker=%s waited_seconds=%s\n' "$1" "$2" "$3"
  return 13
}

dd_emit_stalled() {
  printf 'GLM_STALLED label=%s worker=%s idle_seconds=%s\n' "$1" "$2" "$3"
  return 12
}

dd_sum_cpu_times() {
  awk -v pg="$1" '
    $1 == pg {
      t = $2
      days = 0
      if (index(t, "-") > 0) { split(t, d, "-"); days = d[1]; t = d[2] }
      frac = 0
      if (index(t, ".") > 0) { split(t, f, "."); t = f[1]; frac = f[2] / 100 }
      n = split(t, p, ":")
      secs = 0
      for (i = 1; i <= n; i++) secs = secs * 60 + p[i]
      total += days * 86400 + secs + frac
      seen = 1
    }
    END { if (seen) printf "%.2f\n", total }'
}

dd_group_cpu() {
  ps -axo pgid=,time= 2>/dev/null | dd_sum_cpu_times "$1"
}

dd_files_signature() {
  local file
  if [[ ! -d "$1" ]]; then
    return 0
  fi
  find "$1" -type f | sort | while IFS= read -r file; do
    stat -f '%N %z %m' "$file" 2>/dev/null || stat -c '%n %s %Y' "$file"
  done
}

dd_sample_progress() {
  local dir pgid
  dir="$(dd_state_home)/workers/$1"
  DD_SIG_FILES="$(dd_files_signature "$dir/turns/$(printf '%04d' "$2")")"
  DD_SIG_CPU=""
  pgid="$(dd_kv_get_file "$dir/active/state" provider_pgid 2>/dev/null || true)"
  if [[ "$pgid" =~ ^[1-9][0-9]*$ ]]; then
    DD_SIG_CPU="$(dd_group_cpu "$pgid")"
  fi
}

dd_cpu_grew() {
  if [[ -z "$1" || -z "$2" ]]; then
    return 1
  fi
  dd_number_test "$2" ">" "$1"
}

dd_wait_terminal() {
  local label="$1" worker="$2" started now elapsed timeout remaining out result
  local turn last_progress idle prev_files prev_cpu
  started="$(date +%s)"
  turn="$(dd_registry_get "$DD_SESSION" "$label" turn)"
  last_progress="$started"
  dd_sample_progress "$worker" "$turn"
  prev_files="$DD_SIG_FILES"
  prev_cpu="$DD_SIG_CPU"
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
      TERMINAL)
        return 0
        ;;
      TIMEOUT)
        dd_sample_progress "$worker" "$turn"
        now="$(date +%s)"
        if [[ "$DD_SIG_FILES" != "$prev_files" ]] || dd_cpu_grew "$prev_cpu" "$DD_SIG_CPU"; then
          last_progress="$now"
        fi
        prev_files="$DD_SIG_FILES"
        prev_cpu="$DD_SIG_CPU"
        idle=$((now - last_progress))
        if ((DD_STALL_TIMEOUT > 0 && idle >= DD_STALL_TIMEOUT)); then
          dd_emit_stalled "$label" "$worker" "$idle" || return $?
        fi
        ;;
      *)
        sleep "$DD_POLL"
        ;;
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
  local label="$1" worker="$2" out status class result fallback delta turn
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
  turn="$(dd_kv_get "$out" TURN)"
  if [[ ! "$turn" =~ ^[0-9]+$ || "$result" != *"/turns/$(printf '%04d' "$((10#$turn))")/result.md" ]]; then
    result=""
  fi
  fallback="$(dd_kv_get "$out" FALLBACK_RECOMMENDED)"
  if [[ "$fallback" != true ]]; then
    fallback=false
  fi
  delta="$(dd_format_delta "$(dd_registry_get "$DD_SESSION" "$label" quota_1w_used)" "$(dd_read_quota_1w_used)")"
  dd_git_report "$label"
  printf 'GLM_VERDICT label=%s worker=%s status=%s class=%s result=%s files_changed=%s quota_1w_delta=%s fallback=%s\n' \
    "$label" "$worker" "$status" "$class" "$(dd_encode_token "${result:--}")" "$DD_FILES_CHANGED" "$delta" "$fallback"
  dd_emit_result_sections "$result"
  [[ "$status" == DONE ]]
}

dd_judge() {
  dd_wait_terminal "$1" "$2" || return $?
  dd_emit_verdict "$1" "$2"
}
