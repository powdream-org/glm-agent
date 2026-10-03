#!/usr/bin/env bash

dd_require_label() {
  if ! dd_registry_exists "$DD_SESSION" "$DD_LABEL"; then
    dd_fail "label not found: $DD_LABEL"
  fi
  DD_WORKER="$(dd_registry_get "$DD_SESSION" "$DD_LABEL" worker_id)"
}

dd_worker_status() {
  local out status
  out="$(dd_cli status "$1" 2>/dev/null)" || true
  status="$(dd_kv_get "$out" STATUS)"
  printf '%s\n' "${status:-UNKNOWN}"
}

dd_cmd_send() {
  local rc=0 out role model cwd previous_turn turn
  dd_require_label
  role="$(dd_registry_get "$DD_SESSION" "$DD_LABEL" role)"
  model="$(dd_registry_get "$DD_SESSION" "$DD_LABEL" model)"
  cwd="$(dd_registry_get_cwd "$DD_SESSION" "$DD_LABEL")"
  previous_turn="$(dd_registry_get "$DD_SESSION" "$DD_LABEL" turn)"
  dd_gate_quota || exit $?
  dd_git_snapshot "$cwd"
  dd_read_brief "$DD_TASK_FILE"
  out="$(dd_cli send --async "$DD_WORKER" "$DD_FILE_CONTENT")" || rc=$?
  if ! dd_check_receipt "$rc" "$out" "$role" "$model" "$cwd" "$previous_turn"; then
    dd_emit_not_reached "$DD_REASON" || exit $?
  fi
  if [[ "$(dd_kv_get "$out" WORKER_ID)" != "$DD_WORKER" ]]; then
    dd_emit_not_reached meta-mismatch || exit $?
  fi
  turn="$(dd_kv_get "$out" TURN)"
  dd_registry_put "$DD_SESSION" "$DD_LABEL" \
    scope "$DD_QUOTA_SCOPE" quota_5h_used "$DD_QUOTA_5H_USED" \
    quota_1w_used "$DD_QUOTA_1W_USED" git_head "$DD_GIT_HEAD" \
    git_status_hash "$DD_GIT_STATUS_HASH" turn "$turn" acked false
  dd_save_git_snapshot
  dd_emit_receipt "$DD_LABEL" "$DD_WORKER" "$turn" "$role" "$model" "$cwd"
  if [[ "$DD_WAIT" == true ]]; then
    dd_judge "$DD_LABEL" "$DD_WORKER" || exit $?
  fi
}

dd_cmd_attach() {
  dd_require_label
  dd_judge "$DD_LABEL" "$DD_WORKER" || exit $?
}

dd_cmd_pending() {
  local file label worker acked status state shown=false
  for file in "$(dd_registry_dir "$DD_SESSION")"/*.env; do
    if [[ ! -f "$file" ]]; then
      continue
    fi
    label="$(basename "$file" .env)"
    worker="$(dd_kv_get_file "$file" worker_id)"
    acked="$(dd_kv_get_file "$file" acked)"
    status="$(dd_worker_status "$worker")"
    case "$status" in
      DONE|BLOCKED|INVALID)
        if [[ "$acked" == true ]]; then
          continue
        fi
        state=terminal-unacked
        ;;
      *)
        state=running
        ;;
    esac
    printf 'GLM_PENDING label=%s worker=%s state=%s status=%s\n' "$label" "$worker" "$state" "$status"
    shown=true
  done
  if [[ "$shown" != true ]]; then
    printf 'GLM_PENDING none\n'
  fi
}

dd_cmd_ack() {
  local status
  dd_require_label
  status="$(dd_worker_status "$DD_WORKER")"
  case "$status" in
    DONE|BLOCKED|INVALID)
      dd_registry_put "$DD_SESSION" "$DD_LABEL" acked true
      printf 'GLM_ACK label=%s\n' "$DD_LABEL"
      ;;
    RUNNING)
      printf 'GLM_ACK_REFUSED label=%s reason=running\n' "$DD_LABEL"
      exit 1
      ;;
    *)
      printf 'GLM_ACK_REFUSED label=%s reason=not-terminal\n' "$DD_LABEL"
      exit 1
      ;;
  esac
}

dd_passthrough() {
  local rc=0
  dd_require_label
  printf 'LABEL=%s\n' "$DD_LABEL"
  dd_cli "$1" "$DD_WORKER" || rc=$?
  exit "$rc"
}

dd_cmd_status() {
  dd_passthrough status
}

dd_cmd_result() {
  dd_passthrough result
}

dd_cmd_cancel() {
  dd_passthrough cancel
}

dd_cmd_close() {
  dd_require_label
  if [[ "$(dd_worker_status "$DD_WORKER")" == RUNNING ]]; then
    printf 'GLM_CLOSE_REFUSED label=%s reason=running\n' "$DD_LABEL"
    exit 1
  fi
  dd_cli close "$DD_WORKER"
}
