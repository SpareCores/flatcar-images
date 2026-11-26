#!/usr/bin/env bash
# Boot the oraclecloud-iscsi image in QEMU, both ways, and check the result.
#
# usage: boot-test-iscsi.sh IMAGE.qcow2 [iscsi|vm]    (both when no mode is given)
#
# iscsi: no local disk. iPXE (built from a pinned source, with a script
#   embedded) logs in to an iSCSI target that serves the image (tgt in a docker
#   container) and boots from it, as the firmware of an Oracle Cloud bare metal
#   machine does; it publishes the iBFT table.
# vm:    the same image as a plain virtio disk: no iBFT, the early init must not
#   try to log in to anything.
#
# Ignition runs on the oraclecloud platform against a fake metadata service
# (slirp guestfwd of 169.254.169.254 to tests/boot/metadata-server.py) and installs
# tests/boot/ibft-check.sh, which prints "IBFTCHECK" result lines on the serial
# console on both boots (it reboots once). Pass or fail is decided by grepping
# the serial log: nothing is read from inside the guest.
#
# Needs /dev/kvm, qemu-system-x86_64, qemu-img, OVMF, docker, python3, git, make
# and a C compiler (iPXE), and about 4 GiB of disk.
# Env: WORKDIR (default ./work/boot-test; logs stay there), CACHE_DIR (iPXE build),
# OVMF_CODE, OVMF_VARS (default: the Debian/Ubuntu ovmf package), BOOT_TIMEOUT
# (seconds per mode, default 600).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IPXE_TAG=v2.0.0
IPXE_COMMIT=12798ec29aa8a64d8675c4378b99f5fe28447afb
TARGET_IQN=iqn.2024-01.org.sparecores.flatcar-images:boot-test
TARGET_PORT=3260

[[ $# -ge 1 && $# -le 2 ]] || die "usage: boot-test-iscsi.sh IMAGE.qcow2 [iscsi|vm]"
image=$(realpath "$1")
modes=${2:-"iscsi vm"}
[[ $modes == "iscsi vm" || $modes == iscsi || $modes == vm ]] || die "unknown mode: $modes"
[[ -f $image ]] || die "no such image: $image"
need qemu-system-x86_64 qemu-img docker python3 git make gcc jq curl ss
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not usable"
ovmf_code=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
ovmf_vars=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
[[ -f $ovmf_code && -f $ovmf_vars ]] || die "OVMF firmware not found (set OVMF_CODE and OVMF_VARS)"
timeout_s=${BOOT_TIMEOUT:-600}

work=$(realpath -m "${WORKDIR:-$REPO_ROOT/work/boot-test}")
cache=$(realpath -m "${CACHE_DIR:-$REPO_ROOT/cache}")
tests_boot=$REPO_ROOT/tests/boot
mkdir -p "$work" "$cache"
container=flatcar-images-boot-tgt-$$
qemu_pid=
cleanup() {
  [[ -z $qemu_pid ]] || kill "$qemu_pid" 2>/dev/null || true
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- iPXE: a pinned source tree, the iSCSI boot script embedded ---------------

build_ipxe() {
  local src=$cache/ipxe-$IPXE_COMMIT embed=$work/boot.ipxe
  ipxe=$src/src/bin-x86_64-efi/ipxe.efi
  # The script runs instead of iPXE's own autoboot, which would chain-load the
  # DHCP boot file (iPXE itself) again and again.
  printf '#!ipxe\ndhcp\nsanboot iscsi:169.254.169.2::%s:1:%s\n' "$TARGET_PORT" "$TARGET_IQN" >"$embed"
  if [[ ! -d $src ]]; then
    log "fetching iPXE $IPXE_TAG"
    git clone --quiet --depth 1 --branch "$IPXE_TAG" https://github.com/ipxe/ipxe.git "$src"
  fi
  [[ $(git -C "$src" rev-parse HEAD) == "$IPXE_COMMIT" ]] || die "iPXE $IPXE_TAG is not commit $IPXE_COMMIT"
  log "building iPXE"
  make -C "$src/src" -j"$(nproc)" bin-x86_64-efi/ipxe.efi EMBED="$embed" >"$work/ipxe-build.log" 2>&1 || {
    tail -20 "$work/ipxe-build.log" >&2
    die "building iPXE failed"
  }
}

# --- Ignition config and the fake metadata service -----------------------------

make_ignition() {
  cat >"$work/ibft-check.service" <<'UNIT'
[Unit]
Description=Boot test checks
After=network-online.target iscsid.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/ibft-check

[Install]
WantedBy=multi-user.target
UNIT
  jq -n --arg check "$(base64 -w0 "$tests_boot/ibft-check.sh")" --rawfile unit "$work/ibft-check.service" '
    {ignition: {version: "3.4.0"},
     storage: {files: [{path: "/opt/ibft-check", mode: 493, overwrite: true,
                        contents: {source: ("data:;base64," + $check)}}]},
     systemd: {units: [{name: "ibft-check.service", enabled: true, contents: $unit}]}}' >"$work/config.ign"
}

# --- QEMU ----------------------------------------------------------------------

# run_qemu MODE LOG: start QEMU in the background (pid in qemu_pid).
run_qemu() {
  local mode=$1 logfile=$2 netdev disk=()
  cp "$ovmf_vars" "$work/vars-$mode.fd"
  netdev="user,id=n0,net=169.254.169.0/24,host=169.254.169.2,dhcpstart=169.254.169.15"
  netdev+=",guestfwd=tcp:169.254.169.254:80-cmd:python3 $tests_boot/metadata-server.py $work/config.ign"
  if [[ $mode == iscsi ]]; then
    mkdir -p "$work/tftp"
    cp "$ipxe" "$work/tftp/ipxe.efi"
    netdev+=",tftp=$work/tftp,bootfile=ipxe.efi"
  else
    disk=(-drive "file=$work/vm.raw,format=raw,if=none,id=disk0" -device "virtio-blk-pci,drive=disk0,bootindex=1")
  fi
  : >"$logfile"
  qemu-system-x86_64 -machine q35 -accel kvm -cpu host -smp 2 -m 2048 \
    -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code" -drive "if=pflash,format=raw,file=$work/vars-$mode.fd" \
    "${disk[@]}" -netdev "$netdev" -device virtio-net-pci,netdev=n0 \
    -display none -serial "file:$logfile" -monitor none &
  qemu_pid=$!
}

# serial_text LOG: the log without terminal escapes and carriage returns.
serial_text() { sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\r//g' "$1"; }

# wait_for_log LOG REGEX SECONDS: until the serial log matches, QEMU exits or time runs out.
wait_for_log() {
  local end=$((SECONDS + $3))
  while ((SECONDS < end)); do
    serial_text "$1" | grep -qE "$2" && return 0
    kill -0 "$qemu_pid" 2>/dev/null || return 1
    sleep 2
  done
  return 1
}

# boot_test MODE: boot, wait for both boots to finish their checks, then judge the log.
boot_test() {
  local mode=$1 logfile=$work/serial-$1.log text
  log "== $mode: boot"
  run_qemu "$mode" "$logfile"
  wait_for_log "$logfile" 'IBFTCHECK boot=2 DONE' "$timeout_s" || log "$mode: no 'boot=2 DONE' within ${timeout_s}s (or QEMU exited)"
  # The getty prompt of the second boot comes after the checks.
  wait_for_log "$logfile" ' login: ' 90 || true
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
  qemu_pid=
  text=$(serial_text "$logfile")

  local failures=0 pass1 pass2
  expect() { # DESC COMMAND...
    local desc=$1
    shift
    if "$@" <<<"$text" >/dev/null 2>&1; then log "  ok   $mode: $desc"; else log "  FAIL $mode: $desc"; failures=$((failures + 1)); fi
  }
  expect "first boot reached its checks" grep -q 'IBFTCHECK boot=1 DONE'
  expect "second boot (after reboot) reached its checks" grep -q 'IBFTCHECK boot=2 DONE'
  expect "login prompt on the serial console" grep -q ' login: '
  expect "no check failed" bash -c '! grep -q "IBFTCHECK boot=[0-9] FAIL"'
  pass1=$(grep -c 'IBFTCHECK boot=1 PASS' <<<"$text" || true)
  pass2=$(grep -c 'IBFTCHECK boot=2 PASS' <<<"$text" || true)
  expect "both boots passed the same number of checks ($pass1, $pass2)" test "$pass1" -eq "$pass2" -a "$pass1" -gt 3
  expect "no I/O error in the serial log" bash -c '! grep -qE "I/O error|blk_update_request" '
  if [[ $mode == iscsi ]]; then
    expect "iBFT found by the early init" grep -q 'iBFT: found'
    expect "iSCSI login gave a disk" grep -qE 'iBFT: block devices: sd'
    expect "dracut stage prepared" grep -q 'iBFT: prepared /realinit'
    expect "root on iSCSI" grep -q 'IBFTCHECK boot=1 INFO iSCSI root'
  else
    expect "no iBFT line in the serial log" bash -c '! grep -q "iBFT:"'
    expect "root on the plain disk" grep -q 'IBFTCHECK boot=1 INFO plain disk root'
  fi
  if ((failures > 0)); then
    grep -E 'IBFTCHECK|iBFT:' <<<"$text" >&2 || true
    die "$mode boot test failed (serial log: $logfile)"
  fi
  log "-- $mode: key lines"
  grep -E 'IBFTCHECK boot=[12] (PASS|INFO|DONE)|iBFT:' <<<"$text" | sed 's/^\[[ 0-9.]*\] //' >&2 || true
}

# --- main ------------------------------------------------------------------------

make_ignition
for mode in $modes; do
  case $mode in
    iscsi)
      ss -ltn | grep -q ":$TARGET_PORT " && die "port $TARGET_PORT is in use: the iSCSI target needs it on 127.0.0.1"
      build_ipxe
      docker build --quiet -t flatcar-images-boot-tgt -f "$tests_boot/tgt.Dockerfile" "$tests_boot" >/dev/null
      log "converting the image to raw for the iSCSI target"
      qemu-img convert -f qcow2 -O raw "$image" "$work/iscsi.raw"
      docker run -d --rm --name "$container" -p "127.0.0.1:$TARGET_PORT:$TARGET_PORT" -v "$work:/img" flatcar-images-boot-tgt sh -c "
        tgtd -f --iscsi portal=0.0.0.0:$TARGET_PORT &
        until tgtadm --lld iscsi --mode target --op show >/dev/null 2>&1; do sleep 0.2; done
        tgtadm --lld iscsi --mode target --op new --tid 1 --targetname $TARGET_IQN
        tgtadm --lld iscsi --mode logicalunit --op new --tid 1 --lun 1 --backing-store /img/iscsi.raw
        tgtadm --lld iscsi --mode target --op bind --tid 1 --initiator-address ALL
        wait" >/dev/null
      boot_test iscsi
      docker rm -f "$container" >/dev/null
      rm -f "$work/iscsi.raw"
      ;;
    vm)
      qemu-img convert -f qcow2 -O raw "$image" "$work/vm.raw"
      boot_test vm
      rm -f "$work/vm.raw"
      ;;
  esac
done
log "boot test passed: $modes"
