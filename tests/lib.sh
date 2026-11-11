#!/usr/bin/env bash
# Test helpers. Source from a test file.
# shellcheck shell=bash disable=SC2034
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$TESTS_DIR/.." && pwd)
SCRIPTS=$ROOT/scripts
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILS=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
skip_all() {
  printf 'SKIP %s: %s\n' "$(basename "$0")" "$1"
  # In CI a missing tool is a failure, not a silent skip.
  if [[ -n ${CI:-} ]]; then exit 1; fi
  exit 0
}

# assert_eq DESC EXPECTED ACTUAL
assert_eq() {
  if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
# assert_ok DESC CMD...: command succeeds
assert_ok() {
  local d=$1; shift
  if "$@" >"$T/.cmdout" 2>&1; then pass "$d"; else fail "$d: $(tr '\n' ' ' <"$T/.cmdout")"; fi
}
# assert_fails DESC CMD...: command fails
assert_fails() {
  local d=$1; shift
  if "$@" >"$T/.cmdout" 2>&1; then fail "$d (succeeded)"; else pass "$d"; fi
}
# assert_fails_with DESC REGEX CMD...: fails and output matches
assert_fails_with() {
  local d=$1 re=$2; shift 2
  if "$@" >"$T/.cmdout" 2>&1; then fail "$d (succeeded)"
  elif grep -qE "$re" "$T/.cmdout"; then pass "$d"
  else fail "$d (message does not match '$re': $(tr '\n' ' ' <"$T/.cmdout"))"; fi
}
finish() { [[ $FAILS -eq 0 ]] || { printf '%s: %d failure(s)\n' "$(basename "$0")" "$FAILS"; exit 1; }; }

require_tools() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || skip_all "missing tool $t"; done
}

# make_disk PATH FSTYPE [OEM_NAME]: a 64 MiB GPT disk laid out like a Flatcar
# image (EFI-SYSTEM, BIOS-BOOT, USR-A, USR-B, ROOT-C, OEM, OEM-CONFIG, ROOT),
# random data in every partition except OEM, which gets a btrfs (made like
# Flatcar's: mixed block groups, block group tree), ext4 or vfat filesystem
# labelled OEM holding a stale grub.cfg and one other file, owned by root.
make_disk() {
  local disk=$1 fs=$2 oem_name=${3:-OEM} s
  truncate -s 64M "$disk"
  sgdisk -Z "$disk" >/dev/null 2>&1 || true
  sgdisk -n 1:0:+4M -c "1:EFI-SYSTEM" -n 2:0:+1M -c "2:BIOS-BOOT" \
    -n 3:0:+4M -c "3:USR-A" -n 4:0:+4M -c "4:USR-B" -n 5:0:+1M -c "5:ROOT-C" \
    -n "6:0:+16M" -c "6:$oem_name" -n 7:0:+4M -c "7:OEM-CONFIG" -n 9:0:0 -c "9:ROOT" \
    "$disk" >/dev/null
  local n start size
  while read -r n start size; do
    s=$((start * 512))
    if [[ $n == 6 ]]; then
      local fsimg=$T/oem.fs
      rm -f "$fsimg"; truncate -s $((size * 512)) "$fsimg"
      printf 'stale\n' >"$T/old-grub.cfg"; printf 'keep me\n' >"$T/other.txt"
      case $fs in
        btrfs)
          # shellcheck disable=SC2016
          fakeroot -- bash -euc 'mkdir -p "$1/r"; cp "$2" "$1/r/grub.cfg"; cp "$3" "$1/r/"; chown -R 0:0 "$1/r"
            mkfs.btrfs -q -f -M -O block-group-tree -L OEM --rootdir "$1/r" "$4" >/dev/null' \
            _ "$T/btrfsroot" "$T/old-grub.cfg" "$T/other.txt" "$fsimg"
          rm -rf "$T/btrfsroot" ;;
        ext4)
          mkdir -p "$T/oemroot"; cp "$T/old-grub.cfg" "$T/oemroot/grub.cfg"; cp "$T/other.txt" "$T/oemroot/"
          mkfs.ext4 -q -F -L OEM -d "$T/oemroot" "$fsimg" ;;
        vfat)
          mkfs.vfat -n OEM "$fsimg" >/dev/null
          MTOOLS_SKIP_CHECK=1 mcopy -i "$fsimg" "$T/old-grub.cfg" ::grub.cfg
          MTOOLS_SKIP_CHECK=1 mcopy -i "$fsimg" "$T/other.txt" :: ;;
      esac
      dd if="$fsimg" of="$disk" bs=512 seek="$start" conv=notrunc status=none
    else
      head -c $((size * 512)) /dev/urandom | dd of="$disk" bs=512 seek="$start" conv=notrunc status=none
    fi
  done < <(sfdisk -J "$disk" | jq -r '.partitiontable.partitions[] | "\(.node | sub(".*[^0-9]";"")) \(.start) \(.size)"')
}

# oem_range DISK: prints "start_byte end_byte" of the OEM partition.
oem_range() {
  sfdisk -J "$1" | jq -r '.partitiontable.partitions[] | select(.name=="OEM") | "\(.start*512) \((.start+.size)*512)"'
}

# outside_sum DISK: sha256 of everything outside the OEM partition.
outside_sum() {
  local s e
  read -r s e < <(oem_range "$1")
  { head -c "$s" "$1"; tail -c +$((e + 1)) "$1"; } | sha256sum | cut -d' ' -f1
}
