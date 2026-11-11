#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_tools sgdisk sfdisk jq mkfs.ext4 debugfs e2fsck blkid mkfs.btrfs btrfs btrfs-map-logical fakeroot

btrfs_features() { btrfs inspect-internal dump-super "$1" | awk '$1 ~ /^(nodesize|incompat_flags|compat_ro_flags)$/ {printf "%s=%s ", $1, $2}'; }
want() { printf '# Written by SpareCores/flatcar-images: sets the OEM id (platform) of this image.\nset oem_id="%s"\n' "$1"; }

for fs in btrfs ext4 vfat; do
  if [[ $fs == vfat ]] && ! command -v mcopy >/dev/null; then echo "  skip vfat (no mtools)"; continue; fi
  echo "-- $fs OEM partition"
  d=$T/$fs.img
  make_disk "$d" "$fs"
  pt_before=$(sfdisk -d "$d")
  if [[ $fs == btrfs ]]; then
    read -r s e < <(oem_range "$d")
    dd if="$d" of="$T/orig.part" iflag=skip_bytes,count_bytes skip="$s" count=$((e - s)) bs=1M status=none
    oem_uuid=$(blkid -p -o value -s UUID "$T/orig.part")
    oem_feat=$(btrfs_features "$T/orig.part")
  fi
  out_before=$(outside_sum "$d")
  assert_ok "$fs: patch vultr" "$SCRIPTS/patch-oem.sh" "$d" vultr
  read -r s e < <(oem_range "$d")
  part=$T/$fs.part
  dd if="$d" of="$part" iflag=skip_bytes,count_bytes skip="$s" count=$((e - s)) bs=1M status=none
  if [[ $fs == btrfs ]]; then
    rm -rf "$T/r" && mkdir "$T/r" && btrfs restore "$part" "$T/r" >/dev/null 2>&1
    got=$(cat "$T/r/grub.cfg"; echo x)
    assert_eq "$fs: other file kept" "keep me" "$(cat "$T/r/other.txt")"
    assert_ok "$fs: btrfs check clean" btrfs check --readonly "$part"
    assert_eq "$fs: every inode owned by root" " uid 0 gid 0" \
      "$(btrfs inspect-internal dump-tree -t fs "$part" | grep -oE ' uid [0-9]+ gid [0-9]+' | sort -u)"
    assert_eq "$fs: label kept" "OEM" "$(blkid -p -o value -s LABEL "$part")"
    assert_eq "$fs: UUID kept" "$oem_uuid" "$(blkid -p -o value -s UUID "$part")"
    assert_eq "$fs: features kept (mixed bg, block group tree)" "$oem_feat" "$(btrfs_features "$part")"
  elif [[ $fs == ext4 ]]; then
    got=$(debugfs -R 'cat /grub.cfg' "$part" 2>/dev/null; echo x)
    assert_eq "$fs: other file kept" "keep me" "$(debugfs -R 'cat /other.txt' "$part" 2>/dev/null)"
    assert_ok "$fs: fsck clean" e2fsck -fn "$part"
    assert_ok "$fs: grub.cfg owned by root, 0644" bash -c "debugfs -R 'stat /grub.cfg' '$part' 2>/dev/null | grep -qE 'User: +0 +Group: +0 ' && debugfs -R 'stat /grub.cfg' '$part' 2>/dev/null | grep -qE 'Mode: +0644'"
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
for fs in btrfs ext4; do
  make_disk "$T/dirty.img" "$fs"
  read -r s e < <(oem_range "$T/dirty.img")
  if [[ $fs == ext4 ]]; then
    at=$((s + 1024 + 4)) # the superblock's block count
  else
    dd if="$T/dirty.img" of="$T/dirty.part" iflag=skip_bytes,count_bytes skip="$s" count=$((e - s)) bs=1M status=none
    logical=$(btrfs inspect-internal dump-super "$T/dirty.part" | awk '$1 == "root" {print $2}')
    phys=$(btrfs-map-logical -l "$logical" "$T/dirty.part" 2>/dev/null | awk '/physical/ {print $6; exit}')
    at=$((s + phys + 64)) # inside the root tree block: its checksum no longer matches
  fi
  printf '\xff\xff\xff\xff' | dd of="$T/dirty.img" bs=1 seek="$at" conv=notrunc status=none
  assert_fails_with "$fs: corrupt OEM filesystem fails" "not clean before patching|unsupported OEM filesystem" "$SCRIPTS/patch-oem.sh" "$T/dirty.img" vultr
done
finish
