#!/usr/bin/env bash

dd_emit_not_reached() {
  printf 'GLM_NOT_REACHED reason=%s\n' "$1"
  return 11
}

dd_emit_receipt() {
  printf 'GLM_RECEIPT label=%s worker=%s turn=%s role=%s model=%s cwd=%s scope=%s quota_5h_used=%s quota_1w_used=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$(dd_encode_token "$6")" \
    "$DD_QUOTA_SCOPE" "$DD_QUOTA_5H_USED" "$DD_QUOTA_1W_USED"
}

dd_check_receipt() {
  local rc="$1" text="$2" role="$3" model="$4" cwd="$5" previous_turn="$6"
  local field worker meta_file turn
  export DD_REASON=""
  if [[ "$rc" != 0 ]]; then
    DD_REASON=cli-failed
    return 1
  fi
  for field in WORKER_ID TURN MODEL ROLE STATUS RESULT ERROR_KIND PROVIDER_CODE FALLBACK_RECOMMENDED; do
    if ! dd_kv_has "$text" "$field"; then
      DD_REASON=receipt-incomplete
      return 1
    fi
  done
  worker="$(dd_kv_get "$text" WORKER_ID)"
  meta_file="$(dd_state_home)/workers/$worker/meta"
  if [[ ! "$worker" =~ ^[A-Za-z0-9._-]+$ || "$worker" == . || "$worker" == .. || ! -f "$meta_file" ]]; then
    DD_REASON=meta-missing
    return 1
  fi
  turn="$(dd_kv_get "$text" TURN)"
  if [[ "$(dd_kv_get_file "$meta_file" role)" != "$role" ||
        "$(dd_kv_get_file "$meta_file" model)" != "$model" ||
        "$(dd_kv_get_file "$meta_file" cwd)" != "$cwd" ||
        "$(dd_kv_get "$text" ROLE)" != "$role" ||
        "$(dd_kv_get "$text" MODEL)" != "$model" ||
        ! "$turn" =~ ^[0-9]+$ ]] || ((10#$turn <= previous_turn)); then
    DD_REASON=meta-mismatch
    return 1
  fi
  if [[ "$(dd_kv_get "$text" STATUS)" != RUNNING ]]; then
    DD_REASON=not-running
    return 1
  fi
  return 0
}

dd_absolute_path() {
  printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
}

dd_cmd_run() {
  local rc=0 out worker turn
  if dd_registry_exists "$DD_SESSION" "$DD_LABEL"; then
    dd_fail "label already exists"
  fi
  dd_gate_quota || exit $?
  dd_git_snapshot "$DD_CWD"
  dd_read_brief "$DD_TASK_FILE"
  out="$(dd_cli start --async --role "$DD_ROLE" --model "$DD_MODEL" --cwd "$DD_CWD" "$DD_FILE_CONTENT")" || rc=$?
  if ! dd_check_receipt "$rc" "$out" "$DD_ROLE" "$DD_MODEL" "$DD_CWD" 0; then
    dd_emit_not_reached "$DD_REASON" || exit $?
  fi
  worker="$(dd_kv_get "$out" WORKER_ID)"
  turn="$(dd_kv_get "$out" TURN)"
  dd_registry_put "$DD_SESSION" "$DD_LABEL" \
    label "$DD_LABEL" worker_id "$worker" role "$DD_ROLE" model "$DD_MODEL" \
    cwd "$(dd_encode_token "$DD_CWD")" task_file "$(dd_absolute_path "$DD_TASK_FILE")" \
    started_at "$(dd_now_utc)" scope "$DD_QUOTA_SCOPE" \
    quota_5h_used "$DD_QUOTA_5H_USED" quota_1w_used "$DD_QUOTA_1W_USED" \
    git_head "$DD_GIT_HEAD" git_status_hash "$DD_GIT_STATUS_HASH" \
    turn "$turn" acked false
  dd_save_git_snapshot
  dd_emit_receipt "$DD_LABEL" "$worker" "$turn" "$DD_ROLE" "$DD_MODEL" "$DD_CWD"
  if [[ "$DD_WAIT" == true ]]; then
    dd_judge "$DD_LABEL" "$worker" || exit $?
  fi
}
