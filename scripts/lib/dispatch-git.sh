#!/usr/bin/env bash

dd_status_hash() {
  if [[ -z "$1" ]]; then
    cksum </dev/null | cut -d' ' -f1
  else
    printf '%s\n' "$1" | cksum | cut -d' ' -f1
  fi
}

dd_git_snapshot() {
  local head
  export DD_GIT_HEAD="none" DD_GIT_STATUS_TEXT="" DD_GIT_STATUS_HASH="none"
  head="$(git -C "$1" rev-parse HEAD 2>/dev/null)" || return 0
  DD_GIT_HEAD="$head"
  DD_GIT_STATUS_TEXT="$(git -C "$1" -c core.quotePath=false status --porcelain 2>/dev/null)" || true
  DD_GIT_STATUS_HASH="$(dd_status_hash "$DD_GIT_STATUS_TEXT")"
}

dd_save_git_snapshot() {
  local item
  if [[ "$DD_GIT_HEAD" != none ]]; then
    dd_registry_put_text "$DD_SESSION" "$DD_LABEL" status "$DD_GIT_STATUS_TEXT"
  fi
  if (($(dd_count_allow_paths) > 0)); then
    dd_registry_put_text "$DD_SESSION" "$DD_LABEL" allow \
      "$(for item in "${DD_ALLOW_PATHS[@]}"; do printf '%s\n' "$item"; done)"
  else
    dd_registry_remove_side_file "$DD_SESSION" "$DD_LABEL" allow
  fi
}

dd_porcelain_paths() {
  local line path
  while IFS= read -r line; do
    path="${line:3}"
    path="${path##* -> }"
    path="${path#\"}"
    path="${path%\"}"
    printf '%s\n' "$path"
  done
}

dd_changed_files() {
  local session="$1" label="$2" head cwd status_file
  head="$(dd_registry_get "$session" "$label" git_head)"
  cwd="$(dd_registry_get_cwd "$session" "$label")"
  if [[ -z "$head" || "$head" == none ]]; then
    return 1
  fi
  status_file="$(dd_registry_dir "$session")/$label.status"
  if [[ ! -f "$status_file" ]]; then
    : >"$status_file"
  fi
  {
    git -C "$cwd" diff --name-only "$head..HEAD" 2>/dev/null || true
    comm -13 <(LC_ALL=C sort "$status_file") \
      <(git -C "$cwd" -c core.quotePath=false status --porcelain 2>/dev/null | LC_ALL=C sort) |
      dd_porcelain_paths
  } | sed '/^$/d' | LC_ALL=C sort -u
}

dd_glob_matches() {
  local file="$1" pattern="$2"
  [[ "$file" == ${pattern}"" ]]
}

dd_join_files() {
  dd_encode_token "$(printf '%s\n' "$1" | tr '\n' ',' | sed 's/,$//')"
}

dd_git_report() {
  local label="$1" files count allow_file file pattern in_scope outside=""
  export DD_FILES_CHANGED="na"
  if ! files="$(dd_changed_files "$DD_SESSION" "$label")"; then
    return 0
  fi
  count=0
  if [[ -n "$files" ]]; then
    count="$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
  fi
  DD_FILES_CHANGED="$count"
  if ((count == 0)); then
    return 0
  fi
  if [[ "$(dd_registry_get "$DD_SESSION" "$label" role)" == explorer ]]; then
    printf 'GLM_WARN explorer_modified files=%s\n' "$(dd_join_files "$files")"
  fi
  allow_file="$(dd_registry_dir "$DD_SESSION")/$label.allow"
  if [[ -s "$allow_file" ]]; then
    while IFS= read -r file; do
      in_scope=false
      while IFS= read -r pattern; do
        if dd_glob_matches "$file" "$pattern"; then
          in_scope=true
        fi
      done <"$allow_file"
      if [[ "$in_scope" != true ]]; then
        outside+="$file"$'\n'
      fi
    done <<<"$files"
    if [[ -n "$outside" ]]; then
      printf 'GLM_WARN out_of_scope files=%s\n' "$(dd_join_files "${outside%$'\n'}")"
    fi
  fi
}
