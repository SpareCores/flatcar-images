#!/usr/bin/env bash
# The iBFT pieces that run in the image: the minimal-init patch, the subnet
# arithmetic it uses, and ibft-root-setup. The recipe (oci-ibft.sh) and the
# whole boot are checked by scripts/boot-test-iscsi.sh, which needs KVM.
source "$(dirname "$0")/lib.sh"
require_tools patch sh hexdump awk od busybox env

# shellcheck disable=SC2153
PATCH=$ROOT/patches/minimal-init-ibft.patch
SETUP=$ROOT/overlay/usr/lib/ibft/ibft-root-setup
PARSE=$ROOT/overlay/usr/lib/ibft/ibft-acpi-parse
# The iBFT table iPXE published in the arm64 boot test (QEMU, scripts/boot-test-iscsi.sh).
TABLE=$ROOT/tests/fixtures/ibft-ipxe.bin

echo "-- minimal-init patch"
make_stock_init "$T/stock"
cp "$T/stock" "$T/init"
assert_ok "patch applies without fuzz" patch --fuzz=0 -s "$T/init" "$PATCH"
assert_ok "patched init is valid sh" sh -n "$T/init"
line() { grep -n "$1" "$T/init" | head -1 | cut -d: -f1; }
assert_ok "login runs after sd_mod and before the verity step" \
  test "$(line '^/sbin/modprobe sd_mod')" -lt "$(line '^iscsi_ibft_login$')" -a "$(line '^iscsi_ibft_login$')" -lt "$(line '^debug_sh 2/4')"
assert_ok "realinit preparation runs just before switch_root" \
  test "$(line '^iscsi_ibft_prepare_realinit$')" -lt "$(line '^debug_sh 4/4')"
assert_eq "nothing but the added blocks changed" "0" "$(diff "$T/stock" "$T/init" | grep -c '^<')"

sed 's#/sbin/modprobe sd_mod#/sbin/modprobe sd_mod_renamed#' "$T/stock" >"$T/changed"
assert_fails "patch does not apply when minimal-init changed upstream" patch --fuzz=0 -s -r - "$T/changed" "$PATCH"
grep -v '^debug_sh 4/4' "$T/stock" >"$T/changed"
assert_fails "patch does not apply when the second anchor is gone" patch --fuzz=0 -s -r - "$T/changed" "$PATCH"

echo "-- subnet arithmetic of the init"
# The functions as the init defines them, run by a plain POSIX shell.
sed -n '/^ip_to_int() {/,/^iscsi_ibft_login() {/p' "$T/init" | sed '$d' >"$T/funcs.sh"
off() { sh -c '. "$1"; off_subnet "$2" "$3" "$4"' _ "$T/funcs.sh" "$@"; }
assert_eq "ip_to_int" "168845067" "$(sh -c '. "$1"; ip_to_int 10.16.95.11' _ "$T/funcs.sh")"
assert_ok "link-local target is off the subnet of a 10.16.88.0/21 NIC" off 169.254.0.2 10.16.95.11 21
assert_ok "first address past the subnet is off it" off 10.16.96.0 10.16.95.11 21
assert_ok "last address before the subnet is off it" off 10.16.87.255 10.16.95.11 21
assert_fails "the subnet's gateway is on it" off 10.16.88.1 10.16.95.11 21
assert_fails "an address in the subnet is on it" off 10.16.95.20 10.16.95.11 21
assert_fails "the test setup's gateway is on its /24" off 169.254.169.2 169.254.169.15 24
assert_ok "any other host is off a /32" off 10.0.0.2 10.0.0.1 32
assert_fails "everything is on a /0" off 1.2.3.4 10.0.0.1 0

echo "-- ibft-root-setup"
ibft=$T/ibft initrd=$T/initrd-etc root=$T/root
mkdir -p "$ibft/initiator" "$initrd/iscsi" "$initrd/systemd/network" "$root/etc/iscsi" "$root/usr/share/iscsi"
printf 'iqn.2010-04.org.ipxe:test-initiator\n' >"$ibft/initiator/initiator-name"
printf 'node.session.timeo.replacement_timeout = 6000\n' >"$initrd/iscsi/iscsid.conf"
printf '[Match]\nMACAddress=00:11:22:33:44:55\n' >"$initrd/systemd/network/00-ibft.network"
# Flatcar's default iscsid.conf, which the first boot has in /etc already.
printf 'node.session.timeo.replacement_timeout = 120\n' >"$root/usr/share/iscsi/iscsid.conf"
cp "$root/usr/share/iscsi/iscsid.conf" "$root/etc/iscsi/iscsid.conf"
run_setup() { SYSROOT=$root INITRD_ETC=$initrd IBFT_DIR=$ibft "$SETUP"; }
assert_ok "runs" run_setup
assert_eq "initiator name is the iBFT's" "InitiatorName=iqn.2010-04.org.ipxe:test-initiator" "$(cat "$root/etc/iscsi/initiatorname.iscsi")"
assert_eq "Flatcar's default iscsid.conf is replaced by the 6000 s file" "node.session.timeo.replacement_timeout = 6000" "$(cat "$root/etc/iscsi/iscsid.conf")"
assert_eq "Flatcar's own copy is untouched" "node.session.timeo.replacement_timeout = 120" "$(cat "$root/usr/share/iscsi/iscsid.conf")"
rm "$root/etc/iscsi/iscsid.conf"
ln -s /usr/share/iscsi/iscsid.conf "$root/etc/iscsi/iscsid.conf"
assert_ok "runs with the default as a symlink" run_setup
assert_ok "the link is replaced by a regular file" test -f "$root/etc/iscsi/iscsid.conf" -a ! -L "$root/etc/iscsi/iscsid.conf"
assert_eq "with the 6000 s file" "node.session.timeo.replacement_timeout = 6000" "$(cat "$root/etc/iscsi/iscsid.conf")"
assert_eq "and the file the link pointed to is untouched" "node.session.timeo.replacement_timeout = 120" "$(cat "$root/usr/share/iscsi/iscsid.conf")"
assert_eq "network file is the one the init wrote" "$(cat "$initrd/systemd/network/00-ibft.network")" "$(cat "$root/etc/systemd/network/00-ibft.network")"
assert_eq "iscsid.service is enabled" "/usr/lib/systemd/system/iscsid.service" "$(readlink "$root/etc/systemd/system/multi-user.target.wants/iscsid.service")"
assert_eq "iscsid.socket is enabled" "/usr/lib/systemd/system/iscsid.socket" "$(readlink "$root/etc/systemd/system/sockets.target.wants/iscsid.socket")"
assert_fails "iscsi.service is not enabled" test -e "$root/etc/systemd/system/multi-user.target.wants/iscsi.service" -o -L "$root/etc/systemd/system/multi-user.target.wants/iscsi.service"
printf 'InitiatorName=iqn.other\n' >"$root/etc/iscsi/initiatorname.iscsi"
printf 'custom\n' >"$root/etc/iscsi/iscsid.conf"
printf 'custom network\n' >"$root/etc/systemd/network/00-ibft.network"
assert_ok "runs again" run_setup
assert_eq "an existing initiator name is kept" "InitiatorName=iqn.other" "$(cat "$root/etc/iscsi/initiatorname.iscsi")"
assert_eq "an existing iscsid.conf is kept" "custom" "$(cat "$root/etc/iscsi/iscsid.conf")"
assert_eq "an existing network file is kept" "custom network" "$(cat "$root/etc/systemd/network/00-ibft.network")"
assert_eq "enabling is idempotent" "/usr/lib/systemd/system/iscsid.service" "$(readlink "$root/etc/systemd/system/multi-user.target.wants/iscsid.service")"
: >"$ibft/initiator/initiator-name"
assert_fails_with "no initiator name in the iBFT fails" "no initiator name" run_setup
rm "$ibft/initiator/initiator-name"
assert_fails "no iBFT fails" run_setup

echo "-- ibft-root-setup without /sys/firmware/ibft (arm64): the initiator name comes from ibft.env"
rm -rf "$root/etc/iscsi/initiatorname.iscsi" "$root/etc/ibft.env"
printf 'IBFT_INITIATOR=iqn.2010-04.org.ipxe:from-env\nIBFT_MAC=00:11:22:33:44:55\n' >"$initrd/ibft.env"
assert_ok "runs" run_setup
assert_eq "initiator name is the one of ibft.env" "InitiatorName=iqn.2010-04.org.ipxe:from-env" "$(cat "$root/etc/iscsi/initiatorname.iscsi")"
assert_eq "ibft.env is handed to the real root" "$(cat "$initrd/ibft.env")" "$(cat "$root/etc/ibft.env")"
rm "$initrd/ibft.env"
rm "$root/etc/iscsi/initiatorname.iscsi"
printf 'IBFT_MAC=00:11:22:33:44:55\n' >"$initrd/ibft.env"
assert_fails_with "an ibft.env without initiator fails" "no initiator name" run_setup

# set_bytes FILE OFFSET HEXBYTE...; fix_checksum FILE (byte 9 makes the sum of the table 0).
set_bytes() {
  local out=$1 off=$2 b
  shift 2
  for b in "$@"; do printf %b "\\x$b" | dd of="$out" bs=1 seek="$off" conv=notrunc status=none; off=$((off + 1)); done
}
fix_checksum() {
  local sum
  set_bytes "$1" 9 00
  sum=$(od -An -v -tu1 "$1" | tr -s ' ' '\n' | awk 'NF { s += $1 } END { print s % 256 }')
  set_bytes "$1" 9 "$(printf %02x $(((256 - sum) % 256)))"
}
# patch_table OUT OFFSET HEXBYTE...: a copy of the table with bytes replaced and the checksum fixed.
patch_table() {
  local out=$1
  cp "$TABLE" "$out"
  shift
  set_bytes "$out" "$@"
  fix_checksum "$out"
}
# two_targets OUT FLAGS0 FLAGS1: the table with a second target (port 3261) at 0x110, in the gap before the first.
two_targets() {
  cp "$TABLE" "$1"
  dd if="$TABLE" of="$1" bs=1 skip=$((0x180)) seek=$((0x110)) count=54 conv=notrunc status=none
  set_bytes "$1" $((0x40)) 10 01          # the control structure's second target offset
  set_bytes "$1" $((0x126)) bd 0c         # its port
  set_bytes "$1" $((0x185)) "$2"
  set_bytes "$1" $((0x115)) "$3"
  fix_checksum "$1"
}

# parser_tests LABEL RUNNER...: the parser tests, with the parser run as RUNNER SCRIPT FILE.
parser_tests() {
  local label=$1
  shift
  RUNNER=("$@")
  parse() { "${RUNNER[@]}" "$PARSE" "$1"; }
  echo "-- ibft-acpi-parse ($label)"
  assert_eq "the table iPXE publishes" "IBFT_INITIATOR=iqn.2010-04.org.ipxe:00000000-0000-0000-0000-000000000000
IBFT_MAC=52:54:00:12:34:56
IBFT_IP=169.254.169.15
IBFT_PREFIX=24
IBFT_GATEWAY=169.254.169.2
IBFT_TARGET_IP=169.254.169.2
IBFT_TARGET_PORT=3260
IBFT_TARGET_NAME=iqn.2024-01.org.sparecores.flatcar-images:boot-test" "$(parse "$TABLE")"
  patch_table "$T/prefix.bin" $((0xb6)) 14
  assert_eq "the NIC's prefix length is read from the NIC structure" "IBFT_PREFIX=20" "$(parse "$T/prefix.bin" | grep PREFIX)"
  patch_table "$T/prefix0.bin" $((0xb6)) 00
  assert_fails_with "a prefix length of 0 is refused" "bad prefix length" parse "$T/prefix0.bin"
  patch_table "$T/prefix33.bin" $((0xb6)) 21
  assert_fails_with "a prefix length of 33 is refused" "bad prefix length" parse "$T/prefix33.bin"
  patch_table "$T/port.bin" $((0x196)) 40 1f
  assert_eq "the target port is little endian" "IBFT_TARGET_PORT=8000" "$(parse "$T/port.bin" | grep PORT)"
  two_targets "$T/two-selected.bin" 01 03
  assert_eq "of two valid targets the boot-selected one is used" "IBFT_TARGET_PORT=3261" "$(parse "$T/two-selected.bin" | grep PORT)"
  two_targets "$T/two-none.bin" 01 01
  assert_eq "with none selected the first valid target is used" "IBFT_TARGET_PORT=3260" "$(parse "$T/two-none.bin" | grep PORT)"
  two_targets "$T/two-both.bin" 03 03
  assert_eq "with both selected the first is used" "IBFT_TARGET_PORT=3260" "$(parse "$T/two-both.bin" | grep PORT)"
  two_targets "$T/two-invalid.bin" 00 03
  assert_eq "an invalid first target is skipped" "IBFT_TARGET_PORT=3261" "$(parse "$T/two-invalid.bin" | grep PORT)"
  cp "$TABLE" "$T/badsum.bin"
  printf '\x55' | dd of="$T/badsum.bin" bs=1 seek=100 conv=notrunc status=none
  assert_fails_with "a bad checksum is refused" "bad checksum" parse "$T/badsum.bin"
  head -c 300 "$TABLE" >"$T/short.bin"
  assert_fails_with "a truncated table is refused" "bad table length" parse "$T/short.bin"
  cp "$TABLE" "$T/sig.bin"; printf x | dd of="$T/sig.bin" bs=1 conv=notrunc status=none
  assert_fails_with "a wrong signature is refused" "no iBFT signature" parse "$T/sig.bin"
  patch_table "$T/v6.bin" $((0xb0)) 20  # the NIC's address is no longer ::ffff:a.b.c.d
  assert_fails_with "an address that is not IPv4 is refused" "not an IPv4 address" parse "$T/v6.bin"
  patch_table "$T/name.bin" $((0x23c)) 24  # a "$(" in the target name
  assert_fails_with "a name with shell characters is refused" "unexpected characters" parse "$T/name.bin"
  patch_table "$T/noblock.bin" $((0x185)) 00  # the target block is not valid
  assert_fails_with "a table without a valid target is refused" "no target structure" parse "$T/noblock.bin"
  patch_table "$T/shortinit.bin" $((0x52)) 49 00  # structure lengths below the spec's: 73 (initiator), 101 (NIC), 53 (target)
  assert_fails_with "an initiator structure shorter than 74 bytes is refused" "no initiator structure" parse "$T/shortinit.bin"
  patch_table "$T/shortnic.bin" $((0xa2)) 65 00
  assert_fails_with "a NIC structure shorter than 102 bytes is refused" "no NIC structure" parse "$T/shortnic.bin"
  patch_table "$T/shorttgt.bin" $((0x182)) 35 00
  assert_fails_with "a target structure shorter than 54 bytes is refused" "no target structure" parse "$T/shorttgt.bin"
}
parser_tests "sh and awk of the host" sh
# What the initrd has: busybox's sh, awk and hexdump only.
bb=$T/bb
mkdir "$bb"
for applet in sh awk hexdump; do ln -s "$(command -v busybox)" "$bb/$applet"; done
parser_tests "busybox" env PATH="$bb" "$bb/sh"
finish
