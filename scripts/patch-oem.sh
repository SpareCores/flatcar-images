#!/usr/bin/env bash
# Set the OEM id of a Flatcar disk image, without root.
#
# usage: patch-oem.sh IMAGE OEM_ID [GRUB_LINE...]
#        patch-oem.sh --check IMAGE OEM_ID [GRUB_LINE...]
#
# Writes /grub.cfg into the partition named "OEM" (partition 6 of a Flatcar
# image): `set oem_id="<id>"` plus any extra GRUB lines. Flatcar's main
# grub.cfg sources that file and appends flatcar.oem.id=$oem_id to the kernel
# command line.
#
# How, and why not loop mounts: the partition is cut out of the image with dd
# (offsets from sfdisk's JSON), changed with debugfs (ext4, what Flatcar's OEM
# partition is) or mtools (FAT, accepted too), and copied back with
# dd conv=notrunc. That needs no root, no loop device and no FUSE, so it runs
# the same on GitHub-hosted runners and on a laptop. Afterwards the script
# compares a digest of everything outside the partition (partition table
# included) before and after, and reads grub.cfg back.
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
need sfdisk jq dd sha256sum blkid cmp

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
    ext2 | ext3 | ext4) debugfs -R 'cat /grub.cfg' "$part" 2>/dev/null ;;
    vfat) MTOOLS_SKIP_CHECK=1 mtype -i "$part" ::grub.cfg 2>/dev/null ;;
  esac
}

extract
fstype=$(blkid -p -o value -s TYPE "$part" || true)
case $fstype in
  ext2 | ext3 | ext4) need debugfs e2fsck ;;
  vfat) need mcopy mtype ;;
  *) die "unsupported OEM filesystem '${fstype:-unknown}'" ;;
esac

if [[ $check_only -eq 1 ]]; then
  [[ $(read_cfg; echo x) == "$expected"x ]] || die "grub.cfg of $image does not match the expected content"
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

printf '%s' "$expected" >"$tmp/grub.cfg"
chmod 644 "$tmp/grub.cfg"
case $fstype in
  ext2 | ext3 | ext4)
    e2fsck -fn "$part" >/dev/null 2>&1 || die "OEM filesystem is not clean before patching"
    printf 'rm /grub.cfg\nwrite %s /grub.cfg\n' "$tmp/grub.cfg" >"$tmp/cmds"
    debugfs -w -f "$tmp/cmds" "$part" >/dev/null 2>&1 || true # exit code is unreliable; verified below
    ;;
  vfat)
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$part" "$tmp/grub.cfg" ::grub.cfg
    ;;
esac

[[ $(read_cfg; echo x) == "$expected"x ]] || die "grub.cfg did not read back correctly"
case $fstype in
  ext2 | ext3 | ext4) e2fsck -fn "$part" >/dev/null 2>&1 || die "OEM filesystem is inconsistent after patching" ;;
esac

dd if="$part" of="$image" oflag=seek_bytes seek="$off" bs=4M conv=notrunc status=none
after=$(outside_digest)
[[ $before == "$after" ]] || die "the image changed outside the OEM partition"
"$0" --check "$image" "$oem_id" "$@"
log "patched $image: oem_id=$oem_id"
