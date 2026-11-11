#!/usr/bin/env bash
# Package a patched raw disk image into the formats of a platform.
#
# usage: package.sh IMAGE PLATFORM CHANNEL VERSION ARCH OUTDIR SOURCE_JSON [--all-formats]
#
# Formats come from config/platforms.json. Formats with "publish": false
# (raw images too large for a 2 GiB release asset) are built only with
# --all-formats. Writes OUTDIR/<artifact> and OUTDIR/<artifact>.meta.json
# (the manifest.sh input) for each.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -ge 7 ]] || die "usage: package.sh IMAGE PLATFORM CHANNEL VERSION ARCH OUTDIR SOURCE_JSON [--all-formats]"
image=$1 platform=$2 channel=$3 version=$4 arch=$5 outdir=$6 source_json=$7
all=${8:-}
[[ -f $image ]] || die "no such image: $image"
valid_platform "$platform"; valid_channel "$channel"; valid_version "$version"; valid_arch "$arch"
need jq gzip sha256sum tar truncate
mkdir -p "$outdir"
oem_id=$(platform_field "$platform" .oem_id)

# GCE wants disk.raw in a tar made with --format=oldgnu, sparse, and the disk
# size a whole number of GiB.
GCE_ALIGN=${GCE_ALIGN:-1073741824}

while IFS=$'\t' read -r ext kind publish; do
  if [[ $publish != true && $all != --all-formats ]]; then
    log "skipping unpublished format $ext (use --all-formats)"
    continue
  fi
  name=$(artifact_name "$platform" "$channel" "$version" "$arch" "$ext")
  out=$outdir/$name
  log "packaging $name ($kind)"
  case $kind in
    raw-gzip) gzip -n -6 -c "$image" >"$out.part" ;;
    raw) cp --sparse=always "$image" "$out.part" ;;
    qcow2)
      need qemu-img
      qemu-img convert -f raw -O qcow2 -c "$image" "$out.part"
      ;;
    gce-tar)
      d=$(mktemp -d "$outdir/.gce.XXXXXX")
      cp --sparse=always "$image" "$d/disk.raw"
      cur=$(stat -c %s "$d/disk.raw")
      truncate -s $(((cur + GCE_ALIGN - 1) / GCE_ALIGN * GCE_ALIGN)) "$d/disk.raw"
      tar --format=oldgnu --sparse -czf "$out.part" -C "$d" disk.raw
      rm -rf "$d"
      ;;
    *) die "unknown format kind: $kind" ;;
  esac
  mv "$out.part" "$out"
  bytes=$(stat -c %s "$out")
  if [[ $publish == true && $bytes -gt $MAX_ASSET_BYTES ]]; then
    die "$name is $bytes bytes: over the 2 GiB release asset limit"
  fi
  jq -n --arg name "$name" --arg vendor "$platform" --arg oem "$oem_id" \
    --arg channel "$channel" --arg version "$version" --arg arch "$arch" \
    --arg format "$kind" --arg ext "$ext" --argjson publish "$publish" \
    --argjson size "$bytes" --arg sha256 "$(sha256sum "$out" | cut -d' ' -f1)" \
    --slurpfile src "$source_json" \
    '{name:$name, vendor:$vendor, oem_id:$oem, channel:$channel, version:$version,
      arch:$arch, format:$format, extension:$ext, published:$publish, size:$size,
      sha256:$sha256,
      source_image: {url:$src[0].url, sha512:$src[0].sha512, sha256:$src[0].sha256,
                     size:$src[0].size, signed_by:$src[0].signed_by}}' >"$out.meta.json"
done < <(jq -r --arg p "$platform" '.platforms[$p].formats[] | [.ext, .kind, .publish] | @tsv' "$PLATFORMS_JSON")
