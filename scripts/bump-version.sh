#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
version="${1:-}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'usage: %s <major.minor.patch>\n' "${0##*/}" >&2
  exit 2
}

cli="$REPO_DIR/glm-agent"
plugin="$REPO_DIR/.claude-plugin/plugin.json"
marketplace="$REPO_DIR/.claude-plugin/marketplace.json"

for required_file in "$cli" "$plugin" "$marketplace"; do
  [[ -f "$required_file" ]] || {
    printf 'missing versioned file: %s\n' "$required_file" >&2
    exit 2
  }
done

cli_tmp="$(mktemp "$REPO_DIR/.glm-agent-version.XXXXXX")"
plugin_tmp="$(mktemp "$REPO_DIR/.plugin-version.XXXXXX")"
marketplace_tmp="$(mktemp "$REPO_DIR/.marketplace-version.XXXXXX")"

cleanup() {
  rm -f "$cli_tmp" "$plugin_tmp" "$marketplace_tmp"
}
trap cleanup EXIT

sed "s/^VERSION=\"[^\"]*\"/VERSION=\"$version\"/" "$cli" >"$cli_tmp"
jq --arg version "$version" '.version = $version' "$plugin" >"$plugin_tmp"
jq --arg version "$version" \
  '(.plugins[] | select(.name == "glm-agent") | .version) = $version' \
  "$marketplace" >"$marketplace_tmp"

[[ "$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$cli_tmp")" == "$version" ]] || {
  printf '%s\n' 'failed to update CLI version' >&2
  exit 1
}
[[ "$(jq -er '.version' "$plugin_tmp")" == "$version" ]] || {
  printf '%s\n' 'failed to update plugin version' >&2
  exit 1
}
[[ "$(jq -er '.plugins[] | select(.name == "glm-agent") | .version' \
  "$marketplace_tmp")" == "$version" ]] || {
  printf '%s\n' 'failed to update marketplace version' >&2
  exit 1
}

chmod 755 "$cli_tmp"
chmod 644 "$plugin_tmp" "$marketplace_tmp"
mv "$cli_tmp" "$cli"
mv "$plugin_tmp" "$plugin"
mv "$marketplace_tmp" "$marketplace"
chmod 755 "$cli" "$SCRIPT_DIR/bump-version.sh"

printf 'VERSION=%s\n' "$version"
