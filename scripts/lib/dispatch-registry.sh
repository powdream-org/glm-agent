#!/usr/bin/env bash

dd_registry_dir() {
  printf '%s/dispatch/%s\n' "$(dd_state_home)" "$1"
}

dd_registry_file() {
  printf '%s/%s.env\n' "$(dd_registry_dir "$1")" "$2"
}

dd_registry_exists() {
  [[ -f "$(dd_registry_file "$1" "$2")" ]]
}

dd_registry_get() {
  dd_kv_get_file "$(dd_registry_file "$1" "$2")" "$3"
}

dd_registry_get_cwd() {
  dd_decode_token "$(dd_registry_get "$1" "$2" cwd)"
}

dd_registry_put() {
  local session="$1" label="$2" dir file tmp line existing_key skip i j
  shift 2
  dir="$(dd_registry_dir "$session")"
  file="$dir/$label.env"
  (umask 077 && mkdir -p "$dir")
  chmod 700 "$(dd_state_home)/dispatch" "$dir"
  tmp="$(mktemp "$dir/.$label.XXXXXX")"
  chmod 600 "$tmp"
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      existing_key="${line%%=*}"
      skip=false
      for ((i = 1; i < $#; i += 2)); do
        if [[ "${!i}" == "$existing_key" ]]; then
          skip=true
        fi
      done
      if [[ "$skip" != true ]]; then
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$file"
  fi
  for ((i = 1; i < $#; i += 2)); do
    j=$((i + 1))
    printf '%s=%s\n' "${!i}" "${!j}" >>"$tmp"
  done
  mv "$tmp" "$file"
}

dd_registry_put_text() {
  local dir tmp
  dir="$(dd_registry_dir "$1")"
  tmp="$(mktemp "$dir/.$2.XXXXXX")"
  chmod 600 "$tmp"
  if [[ -n "$4" ]]; then
    printf '%s\n' "$4" >"$tmp"
  fi
  mv "$tmp" "$dir/$2.$3"
}

dd_registry_remove_side_file() {
  rm -f "$(dd_registry_dir "$1")/$2.$3"
}
