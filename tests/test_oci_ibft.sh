#!/usr/bin/env bash
# scripts/oci-ibft.sh on a synthetic oraclecloud disk: an ESP with a kernel image
# that embeds an xz-compressed initramfs, and a btrfs USR-A with iscsistart (the
# host's xz), its library, kernel modules (empty ones, made with objcopy) and
# iscsid.conf.
source "$(dirname "$0")/lib.sh"
require_tools sgdisk sfdisk jq mkfs.btrfs mkfs.vfat mcopy mmd btrfs xz cpio depmod modinfo readelf objcopy patch ldd

KV=6.1.0-test
# Kernel modules that depmod accepts: ELF objects with a .modinfo section.
mods=$T/mods
mkdir "$mods"
for m in dummy nlmon ifb macvlan geneve; do
  printf 'license=GPL\0name=%s\0' "$m" >"$mods/$m.info"
  objcopy -I binary -O elf64-x86-64 --rename-section .data=.modinfo "$mods/$m.info" "$mods/$m.ko"
done
xz_bin=$(command -v xz)
liblzma=$(ldd "$xz_bin" | awk '$1 == "liblzma.so.5" {print $3}')
[[ -n $liblzma ]] || skip_all "xz is not linked to liblzma.so.5"
# Everything xz and liblzma need except liblzma itself is "in the embedded initramfs".
needed=$({ readelf -d "$xz_bin"; readelf -d "$(readlink -f "$liblzma")"; } | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | sort -u | grep -v '^liblzma.so.5$')

u32le() { local i; for i in 0 8 16 24; do printf '%b' "$(printf '\\x%02x' $((($1 >> i) & 255)))"; done; }

# make_image DISK INIT EMBEDDED_DUMMY [ARCH]: the synthetic disk. INIT is the
# embedded minimal-init, EMBEDDED_DUMMY the content of the embedded dummy.ko
# (USR-A's is the one in $mods). ARCH amd64 (default), arm64 (the kernel is a plain arm64 Image and
# USR-A has no iscsi_ibft module) or amd64-noibft (an amd64 kernel, no iscsi_ibft).
make_image() {
  local disk=$1 init=$2 dummy=$3 arch=${4:-amd64} d=$T/img.$RANDOM
  local ird=$d/ird usr=$d/usr kmod=lib/modules/$KV
  mkdir -p "$ird/usr/lib/modules/$KV/kernel/drivers/net" "$ird/usr/lib64" "$usr/bin" "$usr/lib64" "$usr/$kmod/kernel/drivers/net" "$usr/share/iscsi" "$usr/share/flatcar/etc/iscsi"
  cp "$init" "$ird/init"
  chmod 755 "$ird/init"
  cp "$dummy" "$ird/usr/lib/modules/$KV/kernel/drivers/net/dummy.ko"
  for f in dep dep.bin alias alias.bin softdep symbols symbols.bin builtin.bin builtin.alias.bin devname; do : >"$ird/usr/lib/modules/$KV/modules.$f"; done
  for so in $needed; do : >"$ird/usr/lib64/$so"; done
  (cd "$ird" && find . -mindepth 1 | sort | cpio -o -H newc --quiet) | xz -c --check=crc32 >"$d/ird.cpio.xz"
  # The kernel image. amd64: a setup header that points at an xz payload (a
  # "vmlinux" with a decoy xz stream, noise, and the initramfs stream). arm64:
  # the "ARM\x64" magic at offset 56 and the same "vmlinux" as the image itself.
  { head -c 20000 /dev/urandom; echo decoy | xz -c; head -c 3000 /dev/urandom; cat "$d/ird.cpio.xz"; head -c 9000 /dev/urandom; } >"$d/vmlinux"
  if [[ $arch == arm64 ]]; then
    { head -c 56 /dev/zero; printf 'ARM\x64'; cat "$d/vmlinux"; } >"$d/bz"
  else
    xz -c "$d/vmlinux" >"$d/payload.xz"
    head -c 2560 /dev/zero >"$d/bz"
    u32le 0 | dd of="$d/bz" bs=1 seek=$((0x248)) conv=notrunc status=none
    u32le "$(stat -c %s "$d/payload.xz")" | dd of="$d/bz" bs=1 seek=$((0x24c)) conv=notrunc status=none
    cat "$d/payload.xz" >>"$d/bz"
  fi
  truncate -s 16M "$d/esp.img"
  mkfs.vfat "$d/esp.img" >/dev/null
  MTOOLS_SKIP_CHECK=1 mmd -i "$d/esp.img" ::flatcar
  MTOOLS_SKIP_CHECK=1 mcopy -i "$d/esp.img" "$d/bz" ::flatcar/vmlinuz-a
  # USR-A.
  cp "$xz_bin" "$usr/bin/iscsistart"
  cp "$(readlink -f "$liblzma")" "$usr/lib64/liblzma.so.5.test"
  ln -s liblzma.so.5.test "$usr/lib64/liblzma.so.5"
  cp "$mods/dummy.ko" "$d/dummy.ko"
  local pairs="dummy:dummy nlmon:nlmon iscsi_ibft:ifb bnxt_en:macvlan mlx5_core:geneve virtio_net:dummy"
  [[ $arch == amd64 ]] || pairs=${pairs/iscsi_ibft:ifb /}
  for pair in $pairs; do
    xz -c "$mods/${pair#*:}.ko" >"$usr/$kmod/kernel/drivers/net/${pair%%:*}.ko.xz"
  done
  printf '%s\n' 'kernel/drivers/net/dummy.ko.xz:' 'kernel/drivers/net/nlmon.ko.xz:' \
    'kernel/drivers/net/bnxt_en.ko.xz:' \
    'kernel/drivers/net/mlx5_core.ko.xz: kernel/drivers/net/nlmon.ko.xz' 'kernel/drivers/net/virtio_net.ko.xz:' >"$usr/$kmod/modules.dep"
  [[ $arch == amd64 ]] && echo 'kernel/drivers/net/iscsi_ibft.ko.xz: kernel/drivers/net/dummy.ko.xz' >>"$usr/$kmod/modules.dep"
  : >"$usr/$kmod/modules.builtin"; : >"$usr/$kmod/modules.builtin.modinfo"; : >"$usr/$kmod/modules.order"
  printf '# header\nnode.session.timeo.replacement_timeout = 120\nnode.startup = automatic\n' >"$usr/share/flatcar/etc/iscsi/iscsid.conf"
  ln -s ../flatcar/etc/iscsi/iscsid.conf "$usr/share/iscsi/iscsid.conf"
  truncate -s 64M "$d/usr.img"
  mkfs.btrfs -q -f -M -L USR-A --rootdir "$usr" "$d/usr.img" >/dev/null
  truncate -s 128M "$disk"
  sgdisk -Z "$disk" >/dev/null 2>&1 || true
  sgdisk -n 1:0:+16M -c 1:EFI-SYSTEM -n 2:0:+64M -c 2:USR-A "$disk" >/dev/null
  local n start
  while read -r n start; do
    dd if="$d/$([[ $n == 1 ]] && echo esp.img || echo usr.img)" of="$disk" bs=512 seek="$start" conv=notrunc status=none
  done < <(sfdisk -J "$disk" | jq -r '.partitiontable.partitions[] | "\(.node | sub(".*[^0-9]";"")) \(.start)"')
  rm -rf "$d"
}

make_stock_init "$T/stock"
patch --fuzz=0 -s -o "$T/patched" "$T/stock" "$ROOT/patches/minimal-init-ibft.patch"

echo "-- the overlay of a good image"
make_image "$T/good.img" "$T/stock" "$mods/dummy.ko"
assert_ok "oci-ibft.sh succeeds" "$SCRIPTS/oci-ibft.sh" "$T/good.img" "$T/out"
cpio_file=$T/out/flatcar-ibft.cpio
assert_ok "the archive is there" test -s "$cpio_file"
list=$(cpio -tv --quiet <"$cpio_file")
names=$(cpio -t --quiet <"$cpio_file")
mkdir "$T/x"
(cd "$T/x" && cpio -idm --quiet <"$cpio_file")
assert_eq "every entry is owned by root, with mtime 1970" "0" "$(grep -vcE '^[-dl][rwx-]{9} +[0-9]+ root +root .*Jan  1  1970' <<<"$list")"
assert_eq "the entries are sorted" "$(LC_ALL=C sort <<<"$names")" "$names"
assert_fails "it has no /init: no file of the embedded initramfs is replaced" test -e "$T/x/init"
assert_eq "/ibft-init is executable" "755" "$(stat -c %a "$T/x/ibft-init")"
assert_eq "/ibft-init starts with the shebang of minimal-init" "#!/bin/sh" "$(head -n 1 "$T/x/ibft-init")"
# shellcheck disable=SC2016
assert_eq "then the kernel version guard" '[ "$(busybox uname -r)" = "'$KV'" ] || exec /init' "$(sed -n 2p "$T/x/ibft-init")"
assert_ok "the rest is the patched minimal-init" cmp <(tail -n +3 "$T/x/ibft-init") <(tail -n +2 "$T/patched")
assert_ok "iscsistart is in its own directory, executable" test -x "$T/x/usr/lib/ibft/iscsistart"
assert_eq "its missing library is there, with the soname link" "liblzma.so.5.test" "$(readlink "$T/x/usr/lib/ibft/lib64/liblzma.so.5")"
assert_eq "only that library is added, not those the embedded initramfs has" "liblzma.so.5 liblzma.so.5.test" "$(find "$T/x/usr/lib/ibft/lib64" -mindepth 1 -printf "%f\n" | sort | paste -sd" ")"
assert_fails "nothing lands in the embedded initramfs's usr/lib64 or usr/bin" test -e "$T/x/usr/lib64" -o -e "$T/x/usr/bin"

echo "-- a stale initrd (kernel version differs) leaves the embedded init to run"
# The guard line with a busybox that reports another version, and /init as a marker.
mkdir "$T/fakebin"
printf '#!/bin/sh\necho 0.0.0-other\n' >"$T/fakebin/busybox"
chmod 755 "$T/fakebin/busybox"
sed -n 2p "$T/x/ibft-init" | sed 's#exec /init#exec echo EMBEDDED-INIT#' >"$T/guard.sh"
assert_eq "a mismatch execs the embedded init" "EMBEDDED-INIT" "$(PATH=$T/fakebin:$PATH sh "$T/guard.sh")"
printf '#!/bin/sh\necho %s\n' "$KV" >"$T/fakebin/busybox"
assert_eq "a match runs on (the guard line itself succeeds)" "" "$(PATH=$T/fakebin:$PATH sh "$T/guard.sh")"
for m in iscsi_ibft bnxt_en mlx5_core virtio_net nlmon; do
  assert_ok "module $m is added, unpacked" test -f "$T/x/usr/lib/modules/$KV/kernel/drivers/net/$m.ko"
done
assert_fails "a module the embedded initramfs has is not added" test -e "$T/x/usr/lib/modules/$KV/kernel/drivers/net/dummy.ko"
# shellcheck disable=SC2016
assert_ok "modules.dep covers the embedded and the added modules" bash -c 'for m in dummy nlmon iscsi_ibft bnxt_en mlx5_core virtio_net; do grep -q "/$m.ko:" "$1" || exit 1; done' _ "$T/x/usr/lib/modules/$KV/modules.dep"
assert_eq "the index files are the embedded set" "modules.alias modules.alias.bin modules.builtin.alias.bin modules.builtin.bin modules.dep modules.dep.bin modules.devname modules.softdep modules.symbols modules.symbols.bin" \
  "$(find "$T/x/usr/lib/modules/$KV" -maxdepth 1 -name 'modules.*' -printf '%f\n' | sort | paste -sd' ')"
assert_eq "the drivers are listed for the init" "iscsi_ibft bnxt_en mlx5_core virtio_net" "$(paste -sd' ' "$T/x/etc/ibft-modules")"
assert_eq "iscsid.conf has the long replacement_timeout" "node.session.timeo.replacement_timeout = 6000" "$(grep replacement_timeout "$T/x/etc/iscsi/iscsid.conf")"
assert_eq "and keeps the rest of USR-A's" "node.startup = automatic" "$(grep ^node.startup "$T/x/etc/iscsi/iscsid.conf")"
assert_ok "the files of overlay/ are there" test -x "$T/x/usr/lib/ibft/ibft-root-setup" -a -f "$T/x/usr/lib/ibft/ibft-root-setup.service"
# shellcheck disable=SC2016
assert_ok "a second run gives the same bytes" bash -c '"$1" "$2" "$3" 2>/dev/null && cmp -s "$3/flatcar-ibft.cpio" "$4"' _ "$SCRIPTS/oci-ibft.sh" "$T/good.img" "$T/out2" "$cpio_file"

echo "-- images the recipe must refuse"
sed 's#/sbin/modprobe sd_mod#/sbin/modprobe sd_mod_renamed#' "$T/stock" >"$T/stock-changed"
make_image "$T/changed-init.img" "$T/stock-changed" "$mods/dummy.ko"
assert_fails_with "a minimal-init the patch does not fit" "patch does not apply" "$SCRIPTS/oci-ibft.sh" "$T/changed-init.img" "$T/out3"
assert_fails "and it leaves no archive" test -e "$T/out3/flatcar-ibft.cpio"
make_image "$T/changed-mod.img" "$T/stock" "$mods/nlmon.ko"
assert_fails_with "an embedded module that differs from USR-A's" "dummy.ko of the embedded initramfs differs" "$SCRIPTS/oci-ibft.sh" "$T/changed-mod.img" "$T/out4"
assert_fails_with "an image without the partitions" "no EFI-SYSTEM and USR-A" "$SCRIPTS/oci-ibft.sh" "$T/stock" "$T/out5"
make_disk "$T/other.img" btrfs
assert_fails_with "a Flatcar-like disk without a kernel on the ESP" "no flatcar/vmlinuz-a" "$SCRIPTS/oci-ibft.sh" "$T/other.img" "$T/out6"
sgdisk -d 1 "$T/good.img" >/dev/null
assert_fails_with "a disk without an ESP" "no EFI-SYSTEM and USR-A" "$SCRIPTS/oci-ibft.sh" "$T/good.img" "$T/out7"
echo "-- an arm64 image: a plain Image, and no iscsi_ibft in USR-A"
make_image "$T/arm64.img" "$T/stock" "$mods/dummy.ko" arm64
assert_ok "oci-ibft.sh succeeds" "$SCRIPTS/oci-ibft.sh" "$T/arm64.img" "$T/out-arm64"
assert_eq "the drivers are the NIC drivers only" "bnxt_en mlx5_core virtio_net" "$(cpio -i --to-stdout --quiet etc/ibft-modules <"$T/out-arm64/flatcar-ibft.cpio" | paste -sd' ')"
assert_eq "the parser of the raw ACPI table is in the initrd" "ibft-acpi-parse" "$(cpio -t --quiet <"$T/out-arm64/flatcar-ibft.cpio" | grep -o 'ibft-acpi-parse$')"
make_image "$T/arm64-as-amd64.img" "$T/stock" "$mods/dummy.ko" amd64-noibft
assert_fails_with "an amd64 image whose USR-A has no iscsi_ibft is refused" "a driver module is not in USR-A" "$SCRIPTS/oci-ibft.sh" "$T/arm64-as-amd64.img" "$T/out9"
finish
