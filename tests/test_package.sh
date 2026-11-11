#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_tools sgdisk sfdisk jq mkfs.ext4 qemu-img gzip tar

d=$T/disk.img
make_disk "$d" ext4
"$SCRIPTS/patch-oem.sh" "$d" aliyun 2>/dev/null
echo '{"url":"u","sha512":"s5","sha256":"s2","size":1,"signed_by":"F"}' >"$T/src.json"

out=$T/out
assert_ok "package aliyun" "$SCRIPTS/package.sh" "$d" aliyun stable 1.2.3 amd64 "$out" "$T/src.json"
n=$out/flatcar-aliyun-stable-1.2.3-amd64
assert_ok "qcow2 and gz exist" test -s "$n.qcow2" -a -s "$n.img.gz"
assert_ok "qcow2 round-trips to the same bytes" qemu-img compare -f raw -F qcow2 "$d" "$n.qcow2"
assert_eq "gzip round-trips to the same bytes" "$(sha256sum <"$d" | cut -d' ' -f1)" "$(gzip -dc "$n.img.gz" | sha256sum | cut -d' ' -f1)"
assert_eq "gzip is reproducible (no name or mtime)" "$(gzip -n -6 -c "$d" | sha256sum | cut -d' ' -f1)" "$(sha256sum <"$n.img.gz" | cut -d' ' -f1)"
m=$n.img.gz.meta.json
assert_eq "meta: sha256 matches the file" "$(sha256sum <"$n.img.gz" | cut -d' ' -f1)" "$(jq -r .sha256 "$m")"
assert_eq "meta: size matches the file" "$(stat -c %s "$n.img.gz")" "$(jq -r .size "$m")"
assert_eq "meta: vendor, oem id, arch, source digest" "aliyun aliyun amd64 s5" "$(jq -r '"\(.vendor) \(.oem_id) \(.arch) \(.source_image.sha512)"' "$m")"

echo "-- unpublished raw format"
out2=$T/out2
"$SCRIPTS/package.sh" "$d" vultr stable 1.2.3 amd64 "$out2" "$T/src.json" 2>/dev/null
assert_ok "vultr gz built by default" test -s "$out2/flatcar-vultr-stable-1.2.3-amd64.img.gz"
assert_fails "vultr raw not built by default" test -e "$out2/flatcar-vultr-stable-1.2.3-amd64.img"
"$SCRIPTS/package.sh" "$d" vultr stable 1.2.3 amd64 "$out2" "$T/src.json" --all-formats 2>/dev/null
assert_ok "vultr raw identical to the patched disk" cmp "$d" "$out2/flatcar-vultr-stable-1.2.3-amd64.img"
assert_eq "raw is marked unpublished" "false" "$(jq -r .published "$out2/flatcar-vultr-stable-1.2.3-amd64.img.meta.json")"

echo "-- gce tar"
out3=$T/out3
assert_ok "package gce" "$SCRIPTS/package.sh" "$d" gce stable 1.2.3 arm64 "$out3" "$T/src.json"
tarball=$out3/flatcar-gce-stable-1.2.3-arm64.tar.gz
assert_eq "tar holds only disk.raw" "disk.raw" "$(tar -tzf "$tarball")"
mkdir "$T/x"; tar -xzf "$tarball" -C "$T/x"
assert_eq "disk.raw is padded to a whole GiB" "1073741824" "$(stat -c %s "$T/x/disk.raw")"
assert_ok "disk.raw starts with the patched image" cmp -n 67108864 "$d" "$T/x/disk.raw"
assert_eq "tar uses the oldgnu format" "ustar " "$(gzip -dc "$tarball" | dd bs=1 skip=257 count=6 status=none)"

echo "-- errors"
assert_fails "unknown platform" "$SCRIPTS/package.sh" "$d" nope stable 1.2.3 amd64 "$T/o4" "$T/src.json"
assert_fails "missing image" "$SCRIPTS/package.sh" "$T/none" vultr stable 1.2.3 amd64 "$T/o4" "$T/src.json"
finish
