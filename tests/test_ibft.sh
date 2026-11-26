#!/usr/bin/env bash
# The iBFT pieces that run in the image: the minimal-init patch, the subnet
# arithmetic it uses, and ibft-root-setup. The recipe (oci-ibft.sh) and the
# whole boot are checked by scripts/boot-test-iscsi.sh, which needs KVM.
source "$(dirname "$0")/lib.sh"
require_tools patch sh

# shellcheck disable=SC2153
PATCH=$ROOT/patches/minimal-init-ibft.patch
SETUP=$ROOT/overlay/usr/lib/ibft/ibft-root-setup

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
finish
