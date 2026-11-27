#!/bin/bash
# Checks run inside the booted test image, once per boot, by ibft-check.service
# (scripts/boot-test-iscsi.sh installs both with Ignition). Writes
# "IBFTCHECK boot=N PASS|FAIL <name>" lines to the kernel log, which the serial
# console shows (a tty would be hung up when the getty reloads its issue file),
# then "IBFTCHECK boot=N DONE". Reboots after the first boot, to check the second.
set -u

state=/var/lib/ibft-check
mkdir -p "$state"
boot=$(($(cat "$state/boot" 2>/dev/null || echo 0) + 1))
echo "$boot" >"$state/boot"

say() { echo "IBFTCHECK boot=$boot $*" >/dev/kmsg; }
# check NAME CMD...: PASS when the command succeeds.
check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then say "PASS $name"; else say "FAIL $name"; fi
}
# wait_for CMD...: up to 60 s for the command to succeed.
wait_for() {
  for _ in $(seq 60); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

root_src=$(findmnt -n -o SOURCE /)
root_sys=$(readlink -f "/sys/class/block/${root_src##*/}")
rootio() {
  dd if=/dev/zero of=/var/ibft-check-io bs=1M count=32 oflag=direct conv=fsync &&
    dd if=/var/ibft-check-io of=/dev/null bs=1M iflag=direct &&
    rm -f /var/ibft-check-io
}

# env_get KEY: a value the early init saved from the iBFT (/etc/ibft.env).
env_get() { sed -n "s/^IBFT_$1=//p" /etc/ibft.env 2>/dev/null; }

if [[ -d /sys/firmware/ibft || -f /etc/ibft.env ]]; then
  say "INFO iSCSI root, device $root_src, iBFT $([[ -d /sys/firmware/ibft ]] && echo sysfs || echo "raw ACPI table only")"
  # The iBFT's own values: the sysfs tree when the kernel has iscsi_ibft, else
  # (arm64) the file the early init wrote from the raw ACPI table.
  if [[ -d /sys/firmware/ibft ]]; then
    iqn=$(</sys/firmware/ibft/initiator/initiator-name)
    mac=$(</sys/firmware/ibft/ethernet0/mac)
    if [[ -f /etc/ibft.env ]]; then
      check ibft-env-matches-sysfs bash -c "[[ \$(sed -n 's/^IBFT_INITIATOR=//p' /etc/ibft.env) == '$iqn' && \$(sed -n 's/^IBFT_MAC=//p' /etc/ibft.env) == '${mac,,}' ]]"
    fi
  else
    iqn=$(env_get INITIATOR)
    mac=$(env_get MAC)
    check no-iscsi-ibft-module test ! -e /sys/module/iscsi_ibft
    check ibft-acpi-table test -s /sys/firmware/acpi/tables/iBFT
  fi
  dev=$(grep -l -i -x "$mac" /sys/class/net/*/address | cut -d/ -f5)

  check root-on-iscsi-session grep -q /session <<<"$root_sys"
  check iscsid-active wait_for systemctl is-active --quiet iscsid
  check iscsid-enabled-not-iscsi-service bash -c '[[ -L /etc/systemd/system/multi-user.target.wants/iscsid.service && ! -e /etc/systemd/system/multi-user.target.wants/iscsi.service ]]'
  # dracut takes the early init's session over: no second login, no logout.
  # shellcheck disable=SC2016
  check one-iscsi-session bash -c '[[ $(ls /sys/class/iscsi_session | wc -l) -eq 1 ]]'
  check session-logged-in wait_for grep -qx LOGGED_IN /sys/class/iscsi_session/session1/state
  check session-initiator-is-ibft grep -qx "$iqn" /sys/class/iscsi_session/session1/initiatorname
  check initiatorname-file grep -qx "InitiatorName=$iqn" /etc/iscsi/initiatorname.iscsi
  say "INFO recovery_tmo $(cat /sys/class/iscsi_session/session1/recovery_tmo) iscsid.conf $(readlink -f /etc/iscsi/iscsid.conf)"
  check replacement-timeout-6000 grep -qx 6000 /sys/class/iscsi_session/session1/recovery_tmo
  check iscsid-conf-6000 grep -qx 'node.session.timeo.replacement_timeout = 6000' /etc/iscsi/iscsid.conf
  check nic-found test -n "$dev"
  check network-file-applied bash -c "networkctl status '$dev' --no-pager | grep -q 'Network File: /etc/systemd/network/00-ibft.network'"
  addr=$(ip -4 -o addr show dev "$dev" | awk '{print $4}')
  check nic-has-address test -n "$addr"
  check root-io-works rootio
  systemctl restart systemd-networkd
  sleep 5
  check address-kept-over-networkd-restart bash -c "[[ \$(ip -4 -o addr show dev '$dev' | awk '{print \$4}') == '$addr' ]]"
  check root-io-after-networkd-restart rootio
  check session-still-logged-in grep -qx LOGGED_IN /sys/class/iscsi_session/session1/state
else
  say "INFO plain disk root, device $root_src"
  check root-on-virtio grep -q virtio <<<"$root_sys"
  check no-ibft-network-file test ! -e /etc/systemd/network/00-ibft.network
  check iscsid-not-active test "$(systemctl is-active iscsid)" != active
  check root-io-works rootio
fi
check no-io-errors bash -c '! journalctl -k --no-pager | grep -qiE "I/O error|blk_update_request|Buffer I/O"'
# shellcheck disable=SC2016
check no-failed-units bash -c '[[ -z $(systemctl --failed --no-legend --plain | grep -v ibft-check) ]]'
say "INFO failed units: $(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"
say DONE

if [[ $boot -eq 1 ]]; then
  sleep 2
  systemctl reboot
fi
