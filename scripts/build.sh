#!/usr/bin/env bash
# Build the artifacts of one (channel, version, arch, vendor).
#
# usage: build.sh CHANNEL VERSION ARCH VENDOR [OUTDIR]
#
# fetch (verified) -> decompress to a sparse raw disk -> set the OEM id ->
# check -> package. The decompressed disk is about 8 GiB but mostly holes, so
# the work directory needs a few GiB of real space.
#
# The source image comes from config/platforms.json: the generic bz2 image by
# default, or "source_image" (the platform's official image, a qcow2 file). A
# platform with "ibft_overlay" gets the initrd that scripts/oci-ibft.sh builds
# from the image, written to the OEM partition next to grub.cfg.
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
need jq bzip2 dd cp sfdisk

if [[ -n $(platform_field "$vendor" '.built_by // empty') ]]; then
  die "$vendor is not built here but by $(platform_field "$vendor" .built_by): $(platform_field "$vendor" .built_by_reason)"
fi
jq -e --arg p "$vendor" --arg a "$arch" '.platforms[$p].arches | index($a)' "$PLATFORMS_JSON" >/dev/null ||
  die "$vendor is not built for $arch"
if jq -e --arg p "$vendor" --arg c "$channel" '.platforms[$p].skip_channels | index($c)' "$PLATFORMS_JSON" >/dev/null; then
  die "$vendor is not built for the $channel channel: $(platform_field "$vendor" .skip_reason)"
fi

mkdir -p "$outdir" "$workdir" "$cache"
raw=$workdir/$vendor-$channel-$version-$arch.raw
overlay=$workdir/$vendor-$channel-$version-$arch.overlay
trap 'rm -rf "$raw" "$overlay"' EXIT

source_image=$(platform_field "$vendor" '.source_image // "flatcar_production_image.bin.bz2"')
src=$("$(dirname "${BASH_SOURCE[0]}")/fetch.sh" "$channel" "$version" "$arch" "$cache" "$source_image")
source_json=$src.source.json

log "decompressing $src"
case $source_image in
  *.bin.bz2) bzip2 -dc "$src" | dd of="$raw" bs=4M conv=sparse status=none ;;
  *.img) need qemu-img; qemu-img convert -f qcow2 -O raw "$src" "$raw" ;;
  *) die "unknown source image type: $source_image" ;;
esac

oem_files=()
if [[ $(platform_field "$vendor" '.ibft_overlay // false') == true ]]; then
  "$(dirname "${BASH_SOURCE[0]}")/oci-ibft.sh" "$raw" "$overlay"
  oem_files=(--file "$overlay/flatcar-ibft.cpio")
fi

# @USR_A_PARTUUID@ in grub_extra: the image's USR-A partition UUID, as GRUB prints it (lower case).
usr_a_uuid=$(sfdisk --json "$raw" | jq -r '.partitiontable.partitions[] | select(.name == "USR-A") | .uuid | ascii_downcase')
[[ $usr_a_uuid =~ ^[0-9a-f-]{36}$ ]] || die "no USR-A partition UUID in $raw"
oem_id=$(platform_field "$vendor" .oem_id)
mapfile -t extra < <(platform_field "$vendor" '.grub_extra[]' | sed "s/@USR_A_PARTUUID@/$usr_a_uuid/g")
"$(dirname "${BASH_SOURCE[0]}")/patch-oem.sh" "${oem_files[@]}" "$raw" "$oem_id" "${extra[@]}"

flags=()
[[ ${ALL_FORMATS:-0} == 1 ]] && flags=(--all-formats)
"$(dirname "${BASH_SOURCE[0]}")/package.sh" "$raw" "$vendor" "$channel" "$version" "$arch" "$outdir" "$source_json" "${flags[@]}"
log "done: $outdir"
