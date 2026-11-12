#!/usr/bin/env bash
# Remove what a build-gce-arm64.sh run left on the runner.
#
# usage: cleanup-gce-arm64.sh FORK_DIR
#
# Env: CONTAINER (the SDK container of the run, flatcar-gce-arm64-<id>),
# WORK_ROOT (the directory that holds FORK_DIR; default $GITHUB_WORKSPACE).
#
# Removes, and nothing else:
#   - the SDK container CONTAINER and its anonymous volumes (the board root,
#     /build/arm64-usr, lives in the container);
#   - loop devices still attached to disk images (*.bin, *.raw, *.img,
#     *.squashfs) under FORK_DIR/__build__ (a cancelled build_image can leave
#     them; the container shares the host's /dev);
#   - FORK_DIR, which holds __build__ and sdk_container/.cache. It must be a
#     directory named gce-arm64-<number>-<number> directly under WORK_ROOT.
# The SDK image stays in Docker's cache for the next run. Every step is
# best effort and reported; the script fails only on a refused path.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -eq 1 ]] || die "usage: cleanup-gce-arm64.sh FORK_DIR"
fork=$1
container=${CONTAINER:-}
work_root=${WORK_ROOT:-${GITHUB_WORKSPACE:-}}
[[ -n $work_root && -d $work_root ]] || die "WORK_ROOT (or GITHUB_WORKSPACE) must be an existing directory"
work_root=$(cd "$work_root" && pwd -P)
[[ $container =~ ^flatcar-gce-arm64-[a-z0-9-]+$ ]] || die "invalid CONTAINER: $container"
[[ $(basename "$fork") =~ ^gce-arm64-[0-9]+-[0-9]+$ ]] || die "refusing to remove $fork: not a gce-arm64-<run>-<attempt> directory"
if [[ -e $fork ]]; then
  fork_real=$(cd "$fork" && pwd -P)
  [[ $(dirname "$fork_real") == "$work_root" ]] || die "refusing to remove $fork_real: not directly under $work_root"
else
  fork_real=
fi

docker_cmd=${DOCKER:-docker}
if command -v "$docker_cmd" >/dev/null 2>&1; then
  if "$docker_cmd" container inspect "$container" >/dev/null 2>&1; then
    if "$docker_cmd" rm --force --volumes "$container" >/dev/null; then log "removed container $container"
    else log "warning: could not remove container $container"; fi
  else
    log "no container $container"
  fi
else
  log "no docker: container not removed"
fi

if [[ -n $fork_real ]]; then
  if command -v losetup >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      while read -r dev; do
        [[ -n $dev ]] || continue
        if losetup --detach "$dev"; then log "detached $dev ($f)"; else log "warning: could not detach $dev"; fi
      done < <(losetup --noheadings --output NAME --associated "$f" 2>/dev/null || true)
    done < <(find "$fork_real/__build__" -type f \( -name '*.bin' -o -name '*.raw' -o -name '*.img' -o -name '*.squashfs' \) -print0 2>/dev/null)
  fi
  if rm -rf --one-file-system "$fork_real"; then log "removed $fork_real"; else log "warning: could not remove $fork_real"; fi
fi
