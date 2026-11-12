#!/usr/bin/env bash
# Print the build matrix of a channel as JSON: {"include":[{"vendor","arch"}]}.
#
# usage: matrix.sh CHANNEL [VENDORS]
#
# VENDORS is an optional comma-separated filter. Platforms that skip the
# channel (UpCloud on LTS) are left out, and so are platforms with "built_by"
# (an artifact that another workflow builds, GCE arm64).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -ge 1 && $# -le 2 ]] || die "usage: matrix.sh CHANNEL [VENDORS]"
channel=$1 vendors=${2:-}
valid_channel "$channel"
[[ $vendors =~ ^[a-z0-9,]*$ ]] || die "invalid vendor list: $vendors"
need jq

m=$(jq -c --arg c "$channel" --arg v "$vendors" '
  ($v | split(",") | map(select(. != ""))) as $want
  | {include: [.platforms | to_entries[]
      | select(($want | length) == 0 or (.key as $k | $want | index($k)))
      | select(.value.skip_channels | index($c) | not)
      | select(.value.built_by | not)
      | .key as $vendor | .value.arches[] | {vendor: $vendor, arch: .}]}' "$PLATFORMS_JSON")
[[ $(jq '.include | length' <<<"$m") -gt 0 ]] || die "empty matrix for channel $channel, vendors '${vendors:-all}'"
printf '%s\n' "$m"
