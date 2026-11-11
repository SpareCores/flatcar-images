#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_tools sgdisk sfdisk jq mkfs.ext4 debugfs e2fsck blkid

want() { printf '# Written by SpareCores/flatcar-images: sets the OEM id (platform) of this image.\nset oem_id="%s"\n' "$1"; }

for fs in ext4 vfat; do
  if [[ $fs == vfat ]] && ! command -v mcopy >/dev/null; then echo "  skip vfat (no mtools)"; continue; fi
  echo "-- $fs OEM partition"
  d=$T/$fs.img
  make_disk "$d" "$fs"
  pt_before=$(sfdisk -d "$d")
  out_before=$(outside_sum "$d")
  assert_ok "$fs: patch vultr" "$SCRIPTS/patch-oem.sh" "$d" vultr
  read -r s e < <(oem_range "$d")
  part=$T/$fs.part
  dd if="$d" of="$part" iflag=skip_bytes,count_bytes skip="$s" count=$((e - s)) bs=1M status=none
  if [[ $fs == ext4 ]]; then
    got=$(debugfs -R 'cat /grub.cfg' "$part" 2>/dev/null; echo x)
    assert_eq "$fs: other file kept" "keep me" "$(debugfs -R 'cat /other.txt' "$part" 2>/dev/null)"
    assert_ok "$fs: fsck clean" e2fsck -fn "$part"
  else
    got=$(MTOOLS_SKIP_CHECK=1 mtype -i "$part" ::grub.cfg; echo x)
    assert_eq "$fs: other file kept" "keep me" "$(MTOOLS_SKIP_CHECK=1 mtype -i "$part" ::other.txt)"
  fi
  assert_eq "$fs: grub.cfg is exactly the OEM id (stale one replaced)" "$(want vultr; echo x)" "$got"
  assert_eq "$fs: everything outside OEM unchanged" "$out_before" "$(outside_sum "$d")"
  assert_eq "$fs: partition table unchanged" "$pt_before" "$(sfdisk -d "$d")"
  assert_eq "$fs: image size unchanged" "67108864" "$(stat -c %s "$d")"
  assert_ok "$fs: --check passes" "$SCRIPTS/patch-oem.sh" --check "$d" vultr
  assert_fails "$fs: --check fails for another id" "$SCRIPTS/patch-oem.sh" --check "$d" upcloud
  assert_ok "$fs: re-patch with another id (idempotent)" "$SCRIPTS/patch-oem.sh" "$d" aliyun
  assert_ok "$fs: --check sees the new id" "$SCRIPTS/patch-oem.sh" --check "$d" aliyun
  assert_eq "$fs: outside still unchanged" "$out_before" "$(outside_sum "$d")"
  assert_ok "$fs: extra grub lines" "$SCRIPTS/patch-oem.sh" "$d" gce 'set linux_console="console=ttyAMA0"'
  assert_ok "$fs: extra lines check" "$SCRIPTS/patch-oem.sh" --check "$d" gce 'set linux_console="console=ttyAMA0"'
done

echo "-- failures"
make_disk "$T/noname.img" ext4 ROOT-X
assert_fails_with "missing OEM partition fails" "exactly one partition named OEM" "$SCRIPTS/patch-oem.sh" "$T/noname.img" vultr
printf 'not a disk' >"$T/junk.img"
assert_fails "non-GPT file fails" "$SCRIPTS/patch-oem.sh" "$T/junk.img" vultr
assert_fails_with "bad OEM id rejected" "invalid OEM id" "$SCRIPTS/patch-oem.sh" "$T/ext4.img" 'x"; rm'
assert_fails "missing image fails" "$SCRIPTS/patch-oem.sh" "$T/nope.img" vultr
make_disk "$T/dup.img" ext4
sgdisk -c 7:OEM "$T/dup.img" >/dev/null
assert_fails_with "two OEM partitions fail" "exactly one partition named OEM" "$SCRIPTS/patch-oem.sh" "$T/dup.img" vultr
make_disk "$T/dirty.img" ext4
read -r s e < <(oem_range "$T/dirty.img")
printf '\xff\xff\xff\xff' | dd of="$T/dirty.img" bs=1 seek=$((s + 1024 + 4)) conv=notrunc status=none # corrupt the superblock block count
assert_fails "corrupt OEM filesystem fails" "$SCRIPTS/patch-oem.sh" "$T/dirty.img" vultr
finish
