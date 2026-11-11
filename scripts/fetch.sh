#!/usr/bin/env bash
# Download the generic Flatcar image of a release and verify it.
#
# usage: fetch.sh CHANNEL VERSION ARCH OUTDIR
#
# Verifies DIGESTS.asc against Flatcar's image signing key (pinned by
# fingerprint in config/platforms.json), takes the SHA512 from the *signed*
# text, then checks the image against it. A cached image that matches the
# digest is not downloaded again.
#
# Writes OUTDIR/<channel>-<version>-<arch>.bin.bz2 and
# OUTDIR/<channel>-<version>-<arch>.source.json, and prints the image path.
#
# Test overrides: FLATCAR_RELEASE_BASE (see lib.sh), FLATCAR_SIGNING_KEY_FILE,
# FLATCAR_SIGNING_KEY_FPR.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -eq 4 ]] || die "usage: fetch.sh CHANNEL VERSION ARCH OUTDIR"
channel=$1 version=$2 arch=$3 outdir=$4
valid_channel "$channel"; valid_version "$version"; valid_arch "$arch"
need curl gpg jq sha512sum sha256sum awk

key_file=${FLATCAR_SIGNING_KEY_FILE:-$REPO_ROOT/$(jq -r .signing_key.file "$PLATFORMS_JSON")}
key_fpr=${FLATCAR_SIGNING_KEY_FPR:-$(jq -r .signing_key.fingerprint "$PLATFORMS_JSON")}
[[ $key_fpr =~ ^[0-9A-F]{40}$ ]] || die "bad pinned fingerprint: $key_fpr"

base=$(release_url "$channel" "$arch" "$version")
name=flatcar_production_image.bin.bz2
mkdir -p "$outdir"
img=$outdir/$channel-$version-$arch.bin.bz2
meta=$outdir/$channel-$version-$arch.source.json

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME=$tmp/gnupg
mkdir -m 700 "$GNUPGHOME"

# The key file must contain exactly the pinned primary key.
mapfile -t fprs < <(gpg --batch --show-keys --with-colons "$key_file" | awk -F: '$1=="pub"{p=1;next} $1=="fpr"&&p{print $10;p=0}')
[[ ${#fprs[@]} -eq 1 && ${fprs[0]} == "$key_fpr" ]] ||
  die "key file $key_file does not hold exactly the pinned key $key_fpr (found: ${fprs[*]:-none})"
gpg --batch --quiet --import "$key_file" 2>/dev/null

log "fetching $base/$name.DIGESTS.asc"
download "$base/$name.DIGESTS.asc" "$tmp/DIGESTS.asc"

status=$tmp/status
if ! gpg --batch --status-fd 3 --output "$tmp/DIGESTS" --decrypt "$tmp/DIGESTS.asc" 3>"$status" 2>"$tmp/gpg.err"; then
  # An expired subkey (older releases) exits non-zero in some gpg versions
  # but still reports the signature; the status lines below decide.
  :
fi
grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|REVKEYSIG|NO_PUBKEY)' "$status" &&
  die "signature check of DIGESTS.asc failed: $(tr '\n' ' ' <"$tmp/gpg.err")"
grep -qE '^\[GNUPG:\] (GOODSIG|EXPKEYSIG)' "$status" || die "no valid signature on DIGESTS.asc"
# VALIDSIG fields: ... fpr(3) ... primary-key-fpr is the last field.
valid_fpr=$(awk '$2=="VALIDSIG"{print $NF}' "$status")
[[ $valid_fpr == "$key_fpr" ]] || die "DIGESTS.asc is signed by $valid_fpr, expected $key_fpr"
[[ -s $tmp/DIGESTS ]] || die "no signed content extracted from DIGESTS.asc"

want512=$(awk -v n="$name" '/^# SHA512 HASH/{s=1;next} /^#/{s=0} s&&$2==n{print $1}' "$tmp/DIGESTS")
[[ $want512 =~ ^[0-9a-f]{128}$ ]] || die "no SHA512 for $name in the signed DIGESTS"

if [[ -f $img ]] && [[ $(sha512sum "$img" | cut -d' ' -f1) == "$want512" ]]; then
  log "cached image matches the signed digest: $img"
else
  log "downloading $base/$name"
  download "$base/$name" "$img.part"
  got512=$(sha512sum "$img.part" | cut -d' ' -f1)
  if [[ $got512 != "$want512" ]]; then
    rm -f "$img.part"
    die "SHA512 mismatch for $name: signed $want512, downloaded $got512"
  fi
  mv "$img.part" "$img"
fi

jq -n --arg url "$base/$name" --arg sha512 "$want512" \
  --arg sha256 "$(sha256sum "$img" | cut -d' ' -f1)" \
  --argjson size "$(stat -c %s "$img")" \
  --arg signer "$key_fpr" \
  '{url:$url, sha512:$sha512, sha256:$sha256, size:$size, signed_by:$signer}' >"$meta"
printf '%s\n' "$img"
