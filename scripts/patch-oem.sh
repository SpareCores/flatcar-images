#!/usr/bin/env bash
# Set the OEM id of a Flatcar disk image, without root.
#
# usage: patch-oem.sh IMAGE OEM_ID [GRUB_LINE...]
#        patch-oem.sh --check IMAGE OEM_ID [GRUB_LINE...]
#
# Writes /grub.cfg into the partition named "OEM" (partition 6 of a Flatcar
# image): `set oem_id="<id>"` plus any extra GRUB lines, owned by root, mode
# 0644. Flatcar's main grub.cfg sources that file and appends
# flatcar.oem.id=$oem_id to the kernel command line.
#
# How, and why not loop mounts: the partition is cut out of the image with dd
# (offsets from sfdisk's JSON), changed in user space and copied back with
# dd conv=notrunc. That needs no root, no loop device and no FUSE, so it runs
# the same on GitHub-hosted runners and on a laptop. Afterwards the script
# compares a digest of everything outside the partition (partition table
# included) before and after, and reads grub.cfg back.
#
# Filesystems:
# - btrfs (what Flatcar's OEM partition is, see build_library/disk_layout.json):
#   there is no user-space btrfs writer, so the files are extracted with
#   `btrfs restore` and the filesystem is recreated with `mkfs.btrfs --rootdir`,
#   keeping its size, label, UUID, node size, mixed block groups and block
#   group tree. fakeroot makes the files root-owned (mkfs.btrfs copies the
#   owner of the source files).
# - ext4 (debugfs) and FAT (mtools) are accepted too.
#
# --check only reads the image back and compares grub.cfg.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

check_only=0
if [[ ${1:-} == --check ]]; then check_only=1; shift; fi
[[ $# -ge 2 ]] || die "usage: patch-oem.sh [--check] IMAGE OEM_ID [GRUB_LINE...]"
image=$1 oem_id=$2; shift 2
[[ -f $image ]] || die "no such image: $image"
[[ $oem_id =~ ^[a-z0-9_-]+$ ]] || die "invalid OEM id: $oem_id"
need sfdisk jq dd sha256sum blkid cmp truncate

expected=$(printf '# Written by SpareCores/flatcar-images: sets the OEM id (platform) of this image.\nset oem_id="%s"\n' "$oem_id")
for line in "$@"; do expected+=$'\n'"$line"; done
expected+=$'\n'

# Locate the OEM partition: exactly one GPT partition named OEM.
read -r start size ssize < <(sfdisk --json "$image" | jq -r '
  .partitiontable as $t
  | [$t.partitions[]? | select(.name == "OEM")] as $p
  | if ($t.label != "gpt") or ($p | length) != 1 then "bad 0 0"
    else "\($p[0].start) \($p[0].size) \($t.sectorsize // 512)" end')
[[ $start != bad ]] || die "$image has no GPT with exactly one partition named OEM"
off=$((start * ssize))
len=$((size * ssize))
end=$((off + len))
log "OEM partition: offset $off, length $len bytes"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
part=$tmp/oem.part

extract() { dd if="$image" of="$part" iflag=skip_bytes,count_bytes skip="$off" count="$len" bs=4M status=none; }

# read_cfg: print grub.cfg of $part; empty output when absent.
read_cfg() {
  case $fstype in
    btrfs)
      local d=$tmp/read
      rm -rf "$d" && mkdir "$d"
      btrfs restore -S "$part" "$d" >/dev/null 2>&1 && cat "$d/grub.cfg" 2>/dev/null
      rm -rf "$d"
      ;;
    ext2 | ext3 | ext4) debugfs -R 'cat /grub.cfg' "$part" 2>/dev/null ;;
    vfat) MTOOLS_SKIP_CHECK=1 mtype -i "$part" ::grub.cfg 2>/dev/null ;;
  esac
}

# fs_clean: the filesystem in $part checks clean.
fs_clean() {
  case $fstype in
    btrfs) btrfs check --readonly "$part" >/dev/null 2>&1 ;;
    ext2 | ext3 | ext4) e2fsck -fn "$part" >/dev/null 2>&1 ;;
    vfat) true ;;
  esac
}

# root_owned: grub.cfg is owned by root with mode 0644 (btrfs: every inode
# is root-owned). A file owned by the build user's uid would let whichever
# user gets that uid on a node change the kernel command line.
root_owned() {
  local st
  case $fstype in
    btrfs)
      [[ $(btrfs inspect-internal dump-tree -t fs "$part" 2>/dev/null |
        grep -oE ' uid [0-9]+ gid [0-9]+' | sort -u) == " uid 0 gid 0" ]]
      ;;
    ext2 | ext3 | ext4)
      st=$(debugfs -R 'stat /grub.cfg' "$part" 2>/dev/null)
      [[ $st =~ Mode:\ +0644 && $st =~ User:\ +0\ +Group:\ +0[[:space:]] ]]
      ;;
    vfat) true ;;
  esac
}

extract
fstype=$(blkid -p -o value -s TYPE "$part" || true)
case $fstype in
  btrfs) need btrfs mkfs.btrfs fakeroot ;;
  ext2 | ext3 | ext4) need debugfs e2fsck ;;
  vfat) need mcopy mtype ;;
  *) die "unsupported OEM filesystem '${fstype:-unknown}'" ;;
esac

if [[ $check_only -eq 1 ]]; then
  [[ $(read_cfg; echo x) == "$expected"x ]] || die "grub.cfg of $image does not match the expected content"
  root_owned || die "grub.cfg of $image is not owned by root with mode 0644"
  log "OEM id check OK: $oem_id"
  exit 0
fi

# Digest of everything outside the OEM partition.
outside_digest() {
  {
    dd if="$image" iflag=count_bytes bs=4M count="$off" status=none
    dd if="$image" iflag=skip_bytes bs=4M skip="$end" status=none
  } | sha256sum | cut -d' ' -f1
}
before=$(outside_digest)

fs_clean || die "OEM filesystem is not clean before patching"
printf '%s' "$expected" >"$tmp/grub.cfg"
chmod 644 "$tmp/grub.cfg"
case $fstype in
  btrfs)
    super=$(btrfs inspect-internal dump-super "$part")
    field() { awk -v k="$1" '$1 == k { print $2; exit }' <<<"$super"; }
    fsid=$(field fsid) label=$(field label) nodesize=$(field nodesize)
    incompat=$(field incompat_flags) compat_ro=$(field compat_ro_flags)
    [[ $fsid =~ ^[0-9a-f-]{36}$ && $label == OEM && $nodesize =~ ^[0-9]+$ &&
      $incompat =~ ^0x[0-9a-f]+$ && $compat_ro =~ ^0x[0-9a-f]+$ ]] ||
      die "unexpected btrfs superblock on the OEM partition (label '$label')"
    opts=(-q -f -L "$label" -U "$fsid" -n "$nodesize")
    if ((incompat & 0x4)); then opts+=(-M); fi # mixed block groups
    if ((compat_ro & 0x8)); then opts+=(-O block-group-tree); fi
    new=$tmp/new.part
    truncate -s "$len" "$new"
    # Inside fakeroot: extract the files with their owners, add grub.cfg as
    # root, recreate the filesystem from that tree.
    # shellcheck disable=SC2016
    fakeroot -- bash -euo pipefail -c '
      part=$1 cfg=$2 new=$3 root=$4; shift 4
      mkdir "$root"
      btrfs restore -m -S -x "$part" "$root" >/dev/null
      chown 0:0 "$root"; chmod 0755 "$root"
      install -m 0644 -o 0 -g 0 "$cfg" "$root/grub.cfg"
      mkfs.btrfs "$@" --rootdir "$root" "$new" >/dev/null
    ' _ "$part" "$tmp/grub.cfg" "$new" "$tmp/root" "${opts[@]}" ||
      die "recreating the btrfs OEM filesystem failed"
    [[ $(stat -c %s "$new") -eq $len ]] || die "recreated OEM filesystem has the wrong size"
    mv "$new" "$part"
    ;;
  ext2 | ext3 | ext4)
    # debugfs `write` copies the owner of the source file: set root and 0644.
    printf 'rm /grub.cfg\nwrite %s /grub.cfg\nsif /grub.cfg uid 0\nsif /grub.cfg gid 0\nsif /grub.cfg mode 0100644\n' \
      "$tmp/grub.cfg" >"$tmp/cmds"
    debugfs -w -f "$tmp/cmds" "$part" >/dev/null 2>&1 || true # exit code is unreliable; verified below
    ;;
  vfat)
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$part" "$tmp/grub.cfg" ::grub.cfg
    ;;
esac

[[ $(read_cfg; echo x) == "$expected"x ]] || die "grub.cfg did not read back correctly"
root_owned || die "grub.cfg is not owned by root with mode 0644 after patching"
fs_clean || die "OEM filesystem is inconsistent after patching"
[[ $(blkid -p -o value -s TYPE "$part") == "$fstype" ]] || die "OEM filesystem type changed"

dd if="$part" of="$image" oflag=seek_bytes seek="$off" bs=4M conv=notrunc status=none
after=$(outside_digest)
[[ $before == "$after" ]] || die "the image changed outside the OEM partition"
"$0" --check "$image" "$oem_id" "$@"
log "patched $image: oem_id=$oem_id"
