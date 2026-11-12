#!/usr/bin/env bash
# End to end against a fake release server (file://) with a throwaway signing
# key and a tiny synthetic image: fetch, verify, patch, package, manifest.
source "$(dirname "$0")/lib.sh"
require_tools sgdisk sfdisk jq mkfs.btrfs btrfs fakeroot qemu-img gzip tar gpg bzip2 curl sha512sum

export GNUPGHOME=$T/gnupg; mkdir -m 700 "$GNUPGHOME"
gen_key() { # NAME -> prints fingerprint, writes $T/NAME.asc
  gpg --batch --quiet --passphrase '' --quick-generate-key "$1 <$1@example.test>" ed25519 sign never 2>/dev/null
  gpg --batch --with-colons --list-keys "$1@example.test" | awk -F: '$1=="fpr"{print $10; exit}'
}
fpr=$(gen_key good)
gpg --batch --armor --export good@example.test >"$T/good.asc"
gen_key other >/dev/null
gpg --batch --armor --export other@example.test >"$T/other.asc"

# Fake release tree for stable 9999.0.1 amd64 and arm64.
srv=$T/srv
make_disk "$T/base.img" btrfs # as in Flatcar
mk_release() { # ARCH SIGNER
  local dir=$srv/stable/$1-usr/9999.0.1
  mkdir -p "$dir"
  bzip2 -c "$T/base.img" >"$dir/flatcar_production_image.bin.bz2"
  local sum; sum=$(sha512sum "$dir/flatcar_production_image.bin.bz2" | cut -d' ' -f1)
  printf '# MD5 HASH\n0  flatcar_production_image.bin.bz2\n# SHA512 HASH\n%s  flatcar_production_image.bin.bz2\n' "$sum" >"$T/DIGESTS"
  gpg --batch --yes --local-user "$2@example.test" --clearsign --output "$dir/flatcar_production_image.bin.bz2.DIGESTS.asc" "$T/DIGESTS"
}
mk_release amd64 good
mk_release arm64 good

export FLATCAR_RELEASE_BASE=file://$srv
export FLATCAR_SIGNING_KEY_FILE=$T/good.asc FLATCAR_SIGNING_KEY_FPR=$fpr
export WORKDIR=$T/work CACHE_DIR=$T/cache
OUT=$T/out

echo "-- fetch"
assert_ok "fetch verifies and downloads" "$SCRIPTS/fetch.sh" stable 9999.0.1 amd64 "$T/f1"
assert_eq "source.json records the digest" "$(sha512sum "$srv/stable/amd64-usr/9999.0.1/flatcar_production_image.bin.bz2" | cut -d' ' -f1)" "$(jq -r .sha512 "$T/f1/stable-9999.0.1-amd64.source.json")"
assert_eq "source.json records the signer" "$fpr" "$(jq -r .signed_by "$T/f1/stable-9999.0.1-amd64.source.json")"
touch -d '2001-01-01' "$T/f1/stable-9999.0.1-amd64.bin.bz2"
"$SCRIPTS/fetch.sh" stable 9999.0.1 amd64 "$T/f1" >/dev/null 2>&1
assert_eq "cached image is not downloaded again" "2001" "$(date -r "$T/f1/stable-9999.0.1-amd64.bin.bz2" +%Y)"

echo "-- fetch refuses bad input"
printf 'tampered' >>"$srv/stable/arm64-usr/9999.0.1/flatcar_production_image.bin.bz2"
assert_fails_with "tampered image (digest mismatch)" "SHA512 mismatch" "$SCRIPTS/fetch.sh" stable 9999.0.1 arm64 "$T/f2"
assert_fails "tampered image leaves no file behind" test -e "$T/f2/stable-9999.0.1-arm64.bin.bz2"
mk_release arm64 good
sed -i 's/^0  flat/1  flat/' "$srv/stable/arm64-usr/9999.0.1/flatcar_production_image.bin.bz2.DIGESTS.asc"
assert_fails "edited DIGESTS.asc (bad signature)" "$SCRIPTS/fetch.sh" stable 9999.0.1 arm64 "$T/f3"
mk_release arm64 other
assert_fails_with "signed by a key other than the pinned one" "no valid signature|signed by|NO_PUBKEY|failed" "$SCRIPTS/fetch.sh" stable 9999.0.1 arm64 "$T/f4"
assert_fails_with "key file that is not the pinned key" "does not hold exactly the pinned key" \
  env FLATCAR_SIGNING_KEY_FILE="$T/other.asc" "$SCRIPTS/fetch.sh" stable 9999.0.1 amd64 "$T/f5"
assert_fails "unknown release (404)" "$SCRIPTS/fetch.sh" stable 9999.0.2 amd64 "$T/f6"
assert_fails "bad version rejected" "$SCRIPTS/fetch.sh" stable ../x amd64 "$T/f7"
mk_release arm64 good

echo "-- build"
assert_ok "build vultr amd64" "$SCRIPTS/build.sh" stable 9999.0.1 amd64 vultr "$OUT"
assert_ok "build upcloud amd64" "$SCRIPTS/build.sh" stable 9999.0.1 amd64 upcloud "$OUT"
assert_ok "build aliyun arm64" "$SCRIPTS/build.sh" stable 9999.0.1 arm64 aliyun "$OUT"
assert_fails_with "gce arm64 is not built here (build-gce-arm64.yml builds it)" "but by build-gce-arm64.yml" "$SCRIPTS/build.sh" stable 9999.0.1 arm64 gce "$OUT"
assert_ok "work directory is cleaned" test -z "$(ls "$WORKDIR")"
gz=$OUT/flatcar-vultr-stable-9999.0.1-amd64.img.gz
gzip -dc "$gz" >"$T/vultr.raw"
assert_ok "vultr image has the OEM id" "$SCRIPTS/patch-oem.sh" --check "$T/vultr.raw" vultr
assert_eq "everything outside OEM equals the source image" "$(outside_sum "$T/base.img")" "$(outside_sum "$T/vultr.raw")"
gzip -dc "$OUT/flatcar-upcloud-stable-9999.0.1-amd64.img.gz" >"$T/up.raw"
assert_ok "upcloud image has its own OEM id" "$SCRIPTS/patch-oem.sh" --check "$T/up.raw" upcloud
assert_fails "and not vultr's" "$SCRIPTS/patch-oem.sh" --check "$T/up.raw" vultr
qemu-img convert -f qcow2 -O raw "$OUT/flatcar-aliyun-stable-9999.0.1-arm64.qcow2" "$T/ali.raw"
assert_ok "aliyun qcow2 has the aliyun OEM id" "$SCRIPTS/patch-oem.sh" --check "$T/ali.raw" aliyun
assert_ok "ALL_FORMATS builds the raw vultr image" env ALL_FORMATS=1 "$SCRIPTS/build.sh" stable 9999.0.1 amd64 vultr "$T/out-all"
assert_ok "raw vultr image exists" test -s "$T/out-all/flatcar-vultr-stable-9999.0.1-amd64.img"

echo "-- manifest and verify"
assert_ok "manifest" "$SCRIPTS/manifest.sh" "$OUT" stable 9999.0.1
assert_eq "manifest maps version to artifacts" \
  "flatcar-aliyun-stable-9999.0.1-arm64.img.gz flatcar-aliyun-stable-9999.0.1-arm64.qcow2 flatcar-upcloud-stable-9999.0.1-amd64.img.gz flatcar-vultr-stable-9999.0.1-amd64.img.gz" \
  "$(jq -r '[.artifacts[].name] | join(" ")' "$OUT/manifest.json")"
assert_eq "manifest tag and version" "stable-9999.0.1 stable 9999.0.1" "$(jq -r '"\(.tag) \(.channel) \(.version)"' "$OUT/manifest.json")"
assert_eq "manifest keys per artifact" "arch,channel,extension,format,name,oem_id,published,sha256,size,source_image,url,vendor,version" \
  "$(jq -r '.artifacts[0] | keys | join(",")' "$OUT/manifest.json")"
assert_eq "manifest url" "https://github.com/SpareCores/flatcar-images/releases/download/stable-9999.0.1/flatcar-vultr-stable-9999.0.1-amd64.img.gz" \
  "$(jq -r '.artifacts[] | select(.vendor=="vultr") | .url' "$OUT/manifest.json")"
assert_eq "manifest source digest" "$(jq -r .sha512 "$T/f1/stable-9999.0.1-amd64.source.json")" \
  "$(jq -r '.artifacts[] | select(.vendor=="vultr") | .source_image.sha512' "$OUT/manifest.json")"
assert_eq "manifest sha256 equals the file" "$(sha256sum <"$gz" | cut -d' ' -f1)" "$(jq -r '.artifacts[] | select(.vendor=="vultr") | .sha256' "$OUT/manifest.json")"
assert_eq "revision tag" "stable-9999.0.1-r2" "$("$SCRIPTS/manifest.sh" "$OUT" stable 9999.0.1 r2 2>/dev/null; jq -r .tag "$OUT/manifest.json")"
assert_fails "bad revision rejected" "$SCRIPTS/manifest.sh" "$OUT" stable 9999.0.1 'r2;x'
assert_ok "release notes render" "$SCRIPTS/release-notes.sh" "$OUT/manifest.json"
assert_ok "verify.sh (sums only)" env VERIFY_SKIP_SIGNATURES=1 "$SCRIPTS/verify.sh" "$OUT"
printf 'x' >>"$gz"
assert_fails_with "verify.sh catches a modified artifact" "checksum mismatch" env VERIFY_SKIP_SIGNATURES=1 "$SCRIPTS/verify.sh" "$OUT"
finish
