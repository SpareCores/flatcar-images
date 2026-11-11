#!/usr/bin/env bash
# Write manifest.json and SHA256SUMS for the artifacts in a directory.
#
# usage: manifest.sh DIR CHANNEL VERSION [REVISION]
#
# Reads DIR/*.meta.json (written by package.sh). SHA256SUMS lists the published
# artifacts and manifest.json. manifest.json maps the Flatcar version to every
# artifact: vendor, OEM id, format, size, sha256, URL and the digest of the
# source image.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -ge 3 && $# -le 4 ]] || die "usage: manifest.sh DIR CHANNEL VERSION [REVISION]"
dir=$1 channel=$2 version=$3 revision=${4:-}
valid_channel "$channel"; valid_version "$version"
[[ $revision =~ ^(r[0-9]+)?$ ]] || die "invalid revision: $revision"
need jq sha256sum
tag=$(release_tag "$channel" "$version" "$revision")

shopt -s nullglob
metas=("$dir"/*.meta.json)
[[ ${#metas[@]} -gt 0 ]] || die "no *.meta.json in $dir"

jq -s --arg repo "$REPOSITORY" --arg tag "$tag" --arg channel "$channel" \
  --arg version "$version" --arg rev "$revision" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {schema: 1, repository: $repo, tag: $tag, channel: $channel, version: $version,
   revision: (if $rev == "" then null else $rev end), generated_at: $now,
   artifacts: (map(select(.published)
     | . + {url: "https://github.com/\($repo)/releases/download/\($tag)/\(.name)"})
     | sort_by(.name))}' "${metas[@]}" >"$dir/manifest.json"

(
  cd "$dir"
  jq -r '.artifacts[] | "\(.sha256)  \(.name)"' manifest.json
  printf '%s  %s\n' "$(sha256sum manifest.json | cut -d' ' -f1)" manifest.json
) >"$dir/SHA256SUMS"
# Fail early if a listed file is missing or differs.
(cd "$dir" && sha256sum --check --quiet SHA256SUMS)
log "wrote $dir/manifest.json and $dir/SHA256SUMS"
