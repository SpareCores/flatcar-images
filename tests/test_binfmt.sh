#!/usr/bin/env bash
# binfmt-gce-arm64.sh against a stub binfmt_misc directory (a FIFO "register"
# served by a background loop that creates the entry file) and a stub docker.
source "$(dirname "$0")/lib.sh"
S=$SCRIPTS/binfmt-gce-arm64.sh
D=$T/binfmt; mkdir -p "$D" "$T/bin"
export BINFMT_DIR=$D GITHUB_RUN_ID=77 GITHUB_RUN_ATTEMPT=1
# the stub docker: create prints an id, cp writes a fake interpreter, rm is a no-op
cat >"$T/bin/docker" <<'DEOF'
#!/usr/bin/env bash
echo "docker $*" >>"$DOCKER_LOG"
case $1 in
  create) echo cid123 ;;
  cp) printf 'qemu' >"$3" ;;
esac
DEOF
chmod +x "$T/bin/docker"; export PATH=$T/bin:$PATH DOCKER_LOG=$T/docker.log
mkfifo "$D/register"; echo enabled >"$D/status"
(
  while read -r line <"$D/register"; do
    n=${line#:}; n=${n%%:*}
    printf 'enabled\ninterpreter /x\nflags: F\noffset 0\nmagic 7f454c460201010000000000000000000200b700\nmask ff\n' >"$D/$n"
    echo "$line" >>"$T/registered.lines"
  done
) &
reader=$!
trap 'kill $reader 2>/dev/null; rm -rf "$T"' EXIT
state=$T/state

echo "-- register"
assert_fails "invalid image is refused" "$S" register 'bad image;x' "$state"
assert_ok "registers" "$S" register ghcr.io/flatcar/flatcar-sdk-all:4757.0.0 "$state"
name=flatcar-images-qemu-aarch64-77-1
assert_eq "state file names the entry" "$name" "$(cat "$state")"
assert_ok "entry exists" test -f "$D/$name"
assert_ok "F flag and the aarch64 magic" grep -q '^:flatcar-images-qemu-aarch64-77-1:M::.*\\xb7\\x00:.*:.*qemu-aarch64:F$' "$T/registered.lines"
assert_ok "interpreter taken from the SDK image" grep -q 'docker cp cid123:/usr/bin/qemu-aarch64' "$DOCKER_LOG"

echo "-- unregister"
assert_ok "unregisters" "$S" unregister "$state"
assert_eq "exactly that entry got -1" "-1" "$(cat "$D/$name")"
assert_ok "state file removed" test ! -e "$state"
assert_ok "a second cleanup is harmless" "$S" unregister "$state"

echo "-- a handler that already exists is left alone"
rm -f "$D/$name"; : >"$T/registered.lines"
printf 'enabled\ninterpreter /usr/bin/qemu-aarch64-static\nflags: OCF\noffset 0\nmagic 7f454c460201010000000000000000000200b700\nmask ff\n' >"$D/qemu-aarch64"
assert_ok "register skips" "$S" register ghcr.io/flatcar/flatcar-sdk-all:4757.0.0 "$state"
assert_eq "nothing was registered" "" "$(cat "$T/registered.lines")"
assert_ok "no state file" test ! -e "$state"
assert_ok "unregister does nothing" "$S" unregister "$state"
assert_ok "the existing handler is untouched" grep -q '^enabled' "$D/qemu-aarch64"

echo "-- cancelled between the state file and the registration"
rm -f "$D/qemu-aarch64"
echo "$name" >"$state"
assert_ok "unregister without an entry" "$S" unregister "$state"
assert_ok "state file removed" test ! -e "$state"
echo "../../etc/passwd" >"$state"
assert_fails "a forged state file is refused" "$S" unregister "$state"

echo "-- as a user, a file it cannot write is written through sudo"
if [[ $(id -u) -eq 0 ]]; then
  echo "  (skipped: running as root)"
else
  # the stub sudo records its arguments and what it got on standard input
  cat >"$T/bin/sudo" <<'SEOF'
#!/usr/bin/env bash
echo "$*" >>"$SUDO_LOG"
cat >>"$SUDO_LOG"
SEOF
  chmod +x "$T/bin/sudo"; export SUDO_LOG=$T/sudo.log
  ro=$T/readonly; : >"$ro"; chmod 444 "$ro"
  # shellcheck disable=SC2016 # expanded by the inner shell
  assert_ok "write_root" bash -c 'source "$1"; echo -1 | write_root "$2"' _ "$SCRIPTS/lib.sh" "$ro"
  assert_eq "through sudo -n tee, the command resolved on PATH" "-n $(command -v tee) $ro
-1" "$(cat "$SUDO_LOG")"
  assert_eq "the file itself was not touched" "" "$(cat "$ro")"
fi

finish
