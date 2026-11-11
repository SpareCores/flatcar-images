#!/usr/bin/env bash
# Build the artifacts of one (channel, version, arch, vendor).
#
# usage: build.sh CHANNEL VERSION ARCH VENDOR [OUTDIR]
#
# fetch (verified) -> decompress to a sparse raw disk -> set the OEM id ->
# check -> package. The decompressed disk is about 9 GiB but mostly holes, so
# the work directory needs a few GiB of real space.
#
# Env: WORKDIR (default ./work), CACHE_DIR (default ./cache, downloaded images
# keyed by channel/version/arch), ALL_FORMATS=1 to also build unpublished
# formats (the raw image).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -ge 4 && $# -le 5 ]] || die "usage: build.sh CHANNEL VERSION ARCH VENDOR [OUTDIR]"
channel=$1 version=$2 arch=$3 vendor=$4
valid_channel "$channel"; valid_version "$version"; valid_arch "$arch"; valid_platform "$vendor"
outdir=${5:-$REPO_ROOT/out/$channel-$version}
workdir=${WORKDIR:-$REPO_ROOT/work}
cache=${CACHE_DIR:-$REPO_ROOT/cache}
need jq bzip2 dd cp

jq -e --arg p "$vendor" --arg a "$arch" '.platforms[$p].arches | index($a)' "$PLATFORMS_JSON" >/dev/null ||
  die "$vendor is not built for $arch"
if jq -e --arg p "$vendor" --arg c "$channel" '.platforms[$p].skip_channels | index($c)' "$PLATFORMS_JSON" >/dev/null; then
  die "$vendor is not built for the $channel channel: $(platform_field "$vendor" .skip_reason)"
fi

mkdir -p "$outdir" "$workdir" "$cache"
raw=$workdir/$vendor-$channel-$version-$arch.raw
trap 'rm -f "$raw"' EXIT

bz2=$("$(dirname "${BASH_SOURCE[0]}")/fetch.sh" "$channel" "$version" "$arch" "$cache")
source_json=$cache/$channel-$version-$arch.source.json

log "decompressing $bz2"
bzip2 -dc "$bz2" | dd of="$raw" bs=4M conv=sparse status=none

oem_id=$(platform_field "$vendor" .oem_id)
mapfile -t extra < <(platform_field "$vendor" '.grub_extra[]')
"$(dirname "${BASH_SOURCE[0]}")/patch-oem.sh" "$raw" "$oem_id" "${extra[@]}"

flags=()
[[ ${ALL_FORMATS:-0} == 1 ]] && flags=(--all-formats)
"$(dirname "${BASH_SOURCE[0]}")/package.sh" "$raw" "$vendor" "$channel" "$version" "$arch" "$outdir" "$source_json" "${flags[@]}"
log "done: $outdir"
