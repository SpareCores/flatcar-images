#!/usr/bin/env bash
# Set the OEM id of a Flatcar disk image, without root.
#
# usage: patch-oem.sh [--file PATH]... IMAGE OEM_ID [GRUB_LINE...]
#        patch-oem.sh --check [--file PATH]... IMAGE OEM_ID [GRUB_LINE...]
#
# Writes /grub.cfg into the partition named "OEM" (partition 6 of a Flatcar
# image): `set oem_id="<id>"` plus any extra GRUB lines, owned by root, mode
# 0644. Flatcar's main grub.cfg sources that file and appends
# flatcar.oem.id=$oem_id to the kernel command line. Each --file PATH is
# written to the partition's root under its base name, the same way (an
# initrd that the GRUB lines load, for example). Everything else on the
# partition stays.
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
extra_files=()
while [[ ${1:-} == --check || ${1:-} == --file ]]; do
  if [[ $1 == --check ]]; then
    check_only=1; shift
  else
    [[ $# -ge 2 && -f $2 ]] || die "--file needs an existing file"
    [[ $(basename "$2") != grub.cfg ]] || die "--file cannot replace grub.cfg"
    extra_files+=("$2"); shift 2
  fi
done
[[ $# -ge 2 ]] || die "usage: patch-oem.sh [--check] [--file PATH]... IMAGE OEM_ID [GRUB_LINE...]"
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

# read_file NAME: print the root file NAME of $part; empty output when absent.
read_file() {
  case $fstype in
    btrfs)
      local d=$tmp/read
      rm -rf "$d" && mkdir "$d"
      btrfs restore -S --path-regex "^/$1\$" "$part" "$d" >/dev/null 2>&1 && cat "$d/$1" 2>/dev/null
      rm -rf "$d"
      ;;
    ext2 | ext3 | ext4) debugfs -R "cat /$1" "$part" 2>/dev/null ;;
    vfat) MTOOLS_SKIP_CHECK=1 mtype -i "$part" "::$1" 2>/dev/null ;;
  esac
}

# files_match: grub.cfg is the expected text and every extra file is the one given.
files_match() {
  local f
  [[ $(read_file grub.cfg; echo x) == "$expected"x ]] || return 1
  for f in "${extra_files[@]}"; do
    cmp -s <(read_file "$(basename "$f")"; echo x) <(cat "$f"; echo x) || return 1
  done
}

# fs_clean: the filesystem in $part checks clean.
fs_clean() {
  case $fstype in
    btrfs) btrfs check --readonly "$part" >/dev/null 2>&1 ;;
    ext2 | ext3 | ext4) e2fsck -fn "$part" >/dev/null 2>&1 ;;
    vfat) true ;;
  esac
}

# root_owned: grub.cfg and the extra files are owned by root with mode 0644
# (btrfs: every inode is root-owned). A file owned by the build user's uid would
# let whichever user gets that uid on a node change the kernel command line.
root_owned() {
  local st f
  case $fstype in
    btrfs)
      [[ $(btrfs inspect-internal dump-tree -t fs "$part" 2>/dev/null |
        grep -oE ' uid [0-9]+ gid [0-9]+' | sort -u) == " uid 0 gid 0" ]]
      ;;
    ext2 | ext3 | ext4)
      for f in grub.cfg "${extra_files[@]##*/}"; do
        st=$(debugfs -R "stat /$f" "$part" 2>/dev/null)
        [[ $st =~ Mode:\ +0644 && $st =~ User:\ +0\ +Group:\ +0[[:space:]] ]] || return 1
      done
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
  files_match || die "grub.cfg or an extra file of $image does not match the expected content"
  root_owned || die "grub.cfg or an extra file of $image is not owned by root with mode 0644"
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
# Everything to write is staged in one directory.
stage=$tmp/stage
mkdir "$stage"
printf '%s' "$expected" >"$stage/grub.cfg"
((${#extra_files[@]} == 0)) || cp "${extra_files[@]}" "$stage/"
chmod 644 "$stage"/*
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
    # Inside fakeroot: extract the files with their owners, add the staged
    # files as root, recreate the filesystem from that tree.
    # shellcheck disable=SC2016
    fakeroot -- bash -euo pipefail -c '
      part=$1 stage=$2 new=$3 root=$4; shift 4
      mkdir "$root"
      btrfs restore -m -S -x "$part" "$root" >/dev/null
      chown 0:0 "$root"; chmod 0755 "$root"
      install -m 0644 -o 0 -g 0 "$stage"/* "$root/"
      mkfs.btrfs "$@" --rootdir "$root" "$new" >/dev/null
    ' _ "$part" "$stage" "$new" "$tmp/root" "${opts[@]}" ||
      die "recreating the btrfs OEM filesystem failed"
    [[ $(stat -c %s "$new") -eq $len ]] || die "recreated OEM filesystem has the wrong size"
    mv "$new" "$part"
    ;;
  ext2 | ext3 | ext4)
    # debugfs `write` copies the owner of the source file: set root and 0644.
    for f in "$stage"/*; do
      printf 'rm /%s\nwrite %s /%s\nsif /%s uid 0\nsif /%s gid 0\nsif /%s mode 0100644\n' \
        "${f##*/}" "$f" "${f##*/}" "${f##*/}" "${f##*/}" "${f##*/}"
    done >"$tmp/cmds"
    debugfs -w -f "$tmp/cmds" "$part" >/dev/null 2>&1 || true # exit code is unreliable; verified below
    ;;
  vfat)
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$part" "$stage"/* ::
    ;;
esac

files_match || die "grub.cfg or an extra file did not read back correctly"
root_owned || die "grub.cfg or an extra file is not owned by root with mode 0644 after patching"
fs_clean || die "OEM filesystem is inconsistent after patching"
[[ $(blkid -p -o value -s TYPE "$part") == "$fstype" ]] || die "OEM filesystem type changed"

dd if="$part" of="$image" oflag=seek_bytes seek="$off" bs=4M conv=notrunc status=none
after=$(outside_digest)
[[ $before == "$after" ]] || die "the image changed outside the OEM partition"
file_args=()
for f in "${extra_files[@]}"; do file_args+=(--file "$f"); done
"$0" --check "${file_args[@]}" "$image" "$oem_id" "$@"
log "patched $image: oem_id=$oem_id"
