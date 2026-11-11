#!/usr/bin/env bash
# Print the tracked Flatcar releases that have no GitHub release yet.
#
# usage: track.sh [--tags FILE]
#
# For each channel with "track": true in config/channels.json, reads the current
# version from the channel's release server (amd64 version.txt) and prints
# "CHANNEL VERSION" when no release tag <channel>-<version> or
# <channel>-<version>-rN exists. FILE lists existing tags, one per line; without
# it they come from `gh release list`. Nothing is rebuilt over an existing
# release: a fix is a new tag with an -rN suffix, built by hand.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tags_file=
if [[ ${1:-} == --tags ]]; then tags_file=${2:?--tags needs a file}; fi
need curl jq

if [[ -n $tags_file ]]; then
  tags=$(cat "$tags_file")
else
  need gh
  tags=$(gh release list --limit 1000 --json tagName --jq '.[].tagName')
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
while read -r channel; do
  download "$(release_url "$channel" amd64 current)/version.txt" "$tmp" ||
    die "cannot read version.txt of $channel"
  version=$(sed -n 's/^FLATCAR_VERSION=//p' "$tmp")
  valid_version "$version"
  if grep -qxE "$channel-${version//./\\.}(-r[0-9]+)?" <<<"$tags"; then
    log "$channel $version: already released"
  else
    printf '%s %s\n' "$channel" "$version"
  fi
done < <(jq -r '.channels | to_entries[] | select(.value.track) | .key' "$CHANNELS_JSON")
