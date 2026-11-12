#!/usr/bin/env bash
# Check a GCE arm64 image built from the kernel fork (build-gce-arm64.sh).
#
# usage: verify-gce-arm64.sh IMAGE_DIR DISK
#
# IMAGE_DIR is the build_image output directory (__build__/images/arm64-usr/
# <channel>-<version>-a1), DISK the disk.raw of the GCE tarball. Every check
# is run and reported; the exit status is non-zero if any failed.
#
#   kernel config   <image>_kernel_config.txt (written by build_image from the
#                   kernel in the image) has CONFIG_GVE=m;
#   initrd          <image>_realinitrd_contents.txt lists the contents of the full
#                   initrd (usr/lib/flatcar/bootengine.img, a squashfs on the
#                   USR partition, what Ignition runs from) and has gve.ko.
#                   To look yourself: in the SDK container (or any host with
#                   the image mounted) `mount -o loop,ro bootengine.img DIR`,
#                   or unsquashfs it, and find gve.ko under
#                   usr/lib/modules/*/kernel/drivers/net/ethernet/google/gve/;
#   OEM sysext      oem-gce_contents.txt has the GCE udev rules and google_nvme_id;
#   OEM partition   of DISK (GPT partition named OEM, btrfs, read in user space
#                   with `btrfs restore`): grub.cfg sets the OEM id gce and the
#                   arm64 console ttyAMA0, and sysext/oem-gce-*.raw is active and
#                   is byte for byte the oem-gce.raw that was built.
# Needs jq, sfdisk, blkid, dd, sha256sum and btrfs (btrfs-progs); the SDK
# container has them.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -eq 2 ]] || die "usage: verify-gce-arm64.sh IMAGE_DIR DISK"
dir=$1 disk=$2
[[ -d $dir ]] || die "no such directory: $dir"
[[ -f $disk ]] || die "no such disk image: $disk"
need jq sfdisk blkid dd sha256sum btrfs

failed=0
ok() { log "ok:   $1"; }
bad() { log "FAIL: $1"; failed=$((failed + 1)); }
# one_file GLOB: the single file matching the glob in $dir, or nothing.
one_file() {
  local m
  mapfile -t m < <(compgen -G "$dir/$1" || true)
  if [[ ${#m[@]} -eq 1 && -f ${m[0]} ]]; then printf '%s' "${m[0]}"; fi
}

kconfig=$(one_file '*_kernel_config.txt')
if [[ -z $kconfig ]]; then bad "no *_kernel_config.txt in $dir"
elif grep -qx 'CONFIG_GVE=m' "$kconfig"; then ok "kernel config has CONFIG_GVE=m"
else bad "kernel config ($kconfig) does not have CONFIG_GVE=m"; fi

initrd=$(one_file '*_realinitrd_contents.txt')
if [[ -z $initrd ]]; then bad "no *_realinitrd_contents.txt in $dir"
elif grep -qE '(^|[/ ])gve\.ko(\.[a-z]+)?([[:space:]]|$)' "$initrd"; then ok "gve.ko is in the initrd (bootengine.img)"
else bad "gve.ko is not in the initrd ($initrd)"; fi

sysext_contents=$dir/oem-gce_contents.txt
if [[ ! -f $sysext_contents ]]; then bad "no oem-gce_contents.txt in $dir (oem_sysext not built?)"
else
  for f in 65-gce-disk-naming.rules google_nvme_id; do
    if grep -qE "(^|[/ ])$f([[:space:]]|\$)" "$sysext_contents"; then ok "oem-gce sysext has $f"
    else bad "oem-gce sysext has no $f"; fi
  done
fi

# OEM partition of the disk.
read -r start size ssize < <(sfdisk --json "$disk" | jq -r '
  .partitiontable as $t
  | [$t.partitions[]? | select(.name == "OEM")] as $p
  | if ($t.label != "gpt") or ($p | length) != 1 then "bad 0 0"
    else "\($p[0].start) \($p[0].size) \($t.sectorsize // 512)" end')
if [[ $start == bad ]]; then
  bad "$disk has no GPT with exactly one partition named OEM"
else
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  dd if="$disk" of="$tmp/oem.part" iflag=skip_bytes,count_bytes skip=$((start * ssize)) count=$((size * ssize)) bs=4M status=none
  fstype=$(blkid -p -o value -s TYPE "$tmp/oem.part" || true)
  if [[ $fstype != btrfs ]]; then
    bad "the OEM partition is '${fstype:-unknown}', not btrfs"
  elif ! { mkdir "$tmp/oem" && btrfs restore -S "$tmp/oem.part" "$tmp/oem" >/dev/null 2>&1; }; then
    bad "cannot read the OEM partition with btrfs restore"
  else
    grub=$tmp/oem/grub.cfg
    if [[ ! -f $grub ]]; then bad "the OEM partition has no grub.cfg"
    else
      if grep -qE '^set oem_id="gce"$' "$grub"; then ok "OEM grub.cfg sets oem_id gce"; else bad "OEM grub.cfg does not set oem_id gce"; fi
      if grep -q 'ttyAMA0' "$grub"; then ok "OEM grub.cfg has the arm64 console ttyAMA0"; else bad "OEM grub.cfg has no ttyAMA0"; fi
    fi
    mapfile -t sysexts < <(compgen -G "$tmp/oem/sysext/oem-gce-*.raw" || true)
    if [[ ${#sysexts[@]} -ne 1 ]]; then
      bad "expected one sysext/oem-gce-*.raw on the OEM partition, found ${#sysexts[@]}"
    else
      if [[ -e $tmp/oem/sysext/active-oem-gce ]]; then ok "oem-gce sysext is marked active"; else bad "no sysext/active-oem-gce marker"; fi
      built=$dir/oem-gce.raw
      if [[ ! -f $built ]]; then bad "no oem-gce.raw in $dir to compare the sysext with"
      elif [[ $(sha256sum <"${sysexts[0]}") == "$(sha256sum <"$built")" ]]; then ok "the sysext on the OEM partition is the built oem-gce.raw"
      else bad "the sysext on the OEM partition differs from the built oem-gce.raw"; fi
    fi
  fi
fi

[[ $failed -eq 0 ]] || die "$failed check(s) failed"
log "all checks passed"
