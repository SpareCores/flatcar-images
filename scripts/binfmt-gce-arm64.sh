#!/usr/bin/env bash
# Register / unregister the qemu-user binfmt_misc handler for aarch64 that the
# arm64 board of the SDK needs (build_image runs the sysroot's own binaries,
# e.g. localedef, in bwrap: without a handler "Exec format error").
#
#   binfmt-gce-arm64.sh register IMAGE STATEFILE   (as root, before the SDK steps)
#   binfmt-gce-arm64.sh unregister STATEFILE       (always-run cleanup)
#
# binfmt_misc is host-global: while the build job runs, every process of the
# shared runner can execute aarch64 binaries through this handler. The
# interpreter is the static qemu-aarch64 of the SDK image, registered with the
# F flag (opened at registration, so it works inside the SDK container and
# bwrap without the file being visible there). If an aarch64 handler already
# exists it is left untouched and not removed. The entry is named after the run
# and only that entry is removed; STATEFILE records what this job registered, so
# a repeated or cancelled cleanup never removes anything else.
# BINFMT_DIR (default /proc/sys/fs/binfmt_misc) can be pointed at a stub.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dir=${BINFMT_DIR:-/proc/sys/fs/binfmt_misc}
# \x escapes as binfmt_misc takes them; the hex is how the kernel lists the magic back
magic='\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00'
mask='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
magic_hex=7f454c460201010000000000000000000200b700

existing() {
  local f
  for f in "$dir"/*; do
    [[ -f $f ]] || continue
    case ${f##*/} in register | status) continue ;; esac
    grep -qi "^magic $magic_hex" "$f" 2>/dev/null && { echo "${f##*/}"; return 0; }
  done
  return 1
}

register() {
  local image=$1 state=$2 name tmp cid
  [[ $image =~ ^[a-z0-9./:_@-]+$ ]] || die "invalid image: $image"
  [[ -d $dir && -w $dir/register ]] || die "no writable $dir/register (binfmt_misc not mounted, or not root)"
  if name=$(existing); then
    log "an aarch64 binfmt handler exists ($name): left untouched"
    rm -f "$state"
    return 0
  fi
  name=flatcar-images-qemu-aarch64-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}
  [[ $name =~ ^[a-z0-9-]+$ ]] || die "invalid handler name: $name"
  tmp=$(mktemp -d)
  cid=$(docker create "$image" /bin/true)
  # shellcheck disable=SC2064
  trap "docker rm -f '$cid' >/dev/null 2>&1; rm -rf '$tmp'" EXIT
  docker cp "$cid:/usr/bin/qemu-aarch64" "$tmp/qemu-aarch64"
  chmod 755 "$tmp/qemu-aarch64"
  # the state file first: a cancel between the write and the registration is
  # cleaned up as "not registered" (unregister checks the entry exists)
  printf '%s\n' "$name" >"$state"
  printf ':%s:M::%s:%s:%s:F\n' "$name" "$magic" "$mask" "$tmp/qemu-aarch64" >"$dir/register"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f $dir/$name ]] && break; sleep 0.2; done
  [[ -f $dir/$name ]] || die "the handler $name was not registered"
  log "registered binfmt handler $name (host-global until the job's cleanup)"
}

unregister() {
  local state=$1 name
  [[ -f $state ]] || { log "no binfmt handler was registered by this job"; return 0; }
  name=$(<"$state")
  [[ $name =~ ^flatcar-images-qemu-aarch64-[0-9]+-[0-9]+$ || $name =~ ^flatcar-images-qemu-aarch64-[0-9]+$ ]] || die "invalid state file $state"
  if [[ -f $dir/$name ]]; then
    echo -1 >"$dir/$name"
    log "unregistered binfmt handler $name"
  fi
  rm -f "$state"
}

case ${1:-} in
  register) [[ $# -eq 3 ]] || die "usage: $0 register IMAGE STATEFILE"; register "$2" "$3" ;;
  unregister) [[ $# -eq 2 ]] || die "usage: $0 unregister STATEFILE"; unregister "$2" ;;
  *) die "usage: $0 register IMAGE STATEFILE | unregister STATEFILE" ;;
esac
