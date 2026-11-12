#!/usr/bin/env bash
# Build the Flatcar arm64 GCE image from the kernel fork (docs/gce-arm64.md).
#
# usage: build-gce-arm64.sh CHANNEL VERSION [REVISION]
#
# Flatcar's own arm64 kernel has no gVNIC driver and cannot boot on GCE, so
# this builds the image with Flatcar's SDK from a fork of flatcar/scripts
# (SpareCores/flatcar-scripts, branch gce-arm64: CONFIG_GVE=m, the GCE guest
# configs in the arm64 initrd, arm64 keywords for oem-gce, an arm64 console).
# The fork is a few commits on top of the upstream tag <channel>-<version>.
#
# Steps:
#   1. check the fork: it is a git checkout with tags, its HEAD is based on
#      the upstream tag and differs from it, sdk_container/.repo/manifests/
#      version.txt names the requested version;
#   2. in the SDK container (ghcr.io/flatcar/flatcar-sdk-all, the version
#      from FLATCAR_SDK_VERSION in that version.txt, as flatcar/scripts does):
#        ./build_packages --board=arm64-usr
#        ./build_image --board=arm64-usr --group=<channel> prod oem_sysext
#        ./image_to_vm.sh --board=arm64-usr --format=gce
#      Packages come from Flatcar's binary cache (bincache.flatcar-linux.net)
#      except the ones the fork changes (coreos-modules and coreos-kernel are
#      revision-bumped, so portage compiles them), which is the 30 to 60
#      minute cross-compile of the kernel;
#   3. verify-gce-arm64.sh on the result;
#   4. package.sh: OUTDIR/flatcar-gce-<channel>-<version>[-<revision>]-arm64.tar.gz
#      and its .meta.json, with the fork recorded as "source".
# The checks and logs worth keeping (kernel config, initrd and OEM sysext
# contents, package list) are copied to EVIDENCE_DIR.
#
# run_sdk_container is called with -U: the commit is not the tag (the fork
# adds commits), so `git describe` would give stable-4757.2.3-4-g<hash> and the
# SDK would rewrite version.txt to that, pointing the binary cache at a build
# that does not exist. -U uses version.txt as it is.
#
# Everything the build creates is under FORK_DIR (its __build__ directory,
# sdk_container/.cache, .sdk-home) or in the container named CONTAINER; cleanup-gce-arm64.sh
# removes both. The SDK image stays cached.
#
# Env:
#   FORK_DIR          checkout of the fork, with all tags (required)
#   FORK_REPOSITORY   recorded in the manifest (default SpareCores/flatcar-scripts)
#   FORK_REF          recorded in the manifest (required)
#   OUTDIR            artifact directory (default ./out/gce-arm64-<channel>-<version>)
#   EVIDENCE_DIR      default OUTDIR.evidence
#   CONTAINER         SDK container name (default flatcar-gce-arm64-<pid>)
#   NICE_CMD          prefix of the commands in the container (default
#                     "nice -n 10 ionice -c 2 -n 7": the runner is shared)
#   MIN_FREE_GB       refuse to start with less free space (default 100)
#   VERIFY_RUNNER     sdk (default: verify-gce-arm64.sh runs in the SDK container,
#                     which has btrfs-progs and sfdisk) or host
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -ge 2 && $# -le 3 ]] || die "usage: build-gce-arm64.sh CHANNEL VERSION [REVISION]"
channel=$1 version=$2 revision=${3:-}
valid_channel "$channel"; valid_version "$version"
[[ $revision =~ ^(r[0-9]+)?$ ]] || die "invalid revision: $revision"
fork=${FORK_DIR:-}
[[ -n $fork && -d $fork ]] || die "FORK_DIR must be the checkout of the fork"
fork=$(cd "$fork" && pwd)
fork_repository=${FORK_REPOSITORY:-SpareCores/flatcar-scripts}
fork_ref=${FORK_REF:-}
[[ -n $fork_ref ]] || die "FORK_REF must be set"
valid_fork_repository "$fork_repository"; valid_fork_ref "$fork_ref"
outdir=${OUTDIR:-$REPO_ROOT/out/gce-arm64-$channel-$version}
evidence=${EVIDENCE_DIR:-$outdir.evidence}
container=${CONTAINER:-flatcar-gce-arm64-$$}
[[ $container =~ ^flatcar-gce-arm64-[a-z0-9-]+$ ]] || die "invalid container name: $container"
nice_cmd=${NICE_CMD-nice -n 10 ionice -c 2 -n 7}
min_free=${MIN_FREE_GB:-100}
runner=${VERIFY_RUNNER:-sdk}
[[ $runner =~ ^(sdk|host)$ ]] || die "invalid VERIFY_RUNNER: $runner"
need git jq tar sha256sum df awk

board=arm64-usr
tag=$channel-$version

# --- 1. the fork
git -C "$fork" rev-parse --git-dir >/dev/null 2>&1 || die "$fork is not a git checkout"
upstream=$(git -C "$fork" rev-parse -q --verify "refs/tags/$tag^{commit}") ||
  die "the fork checkout has no tag $tag (fetch with tags: the fork must be based on that Flatcar release)"
head=$(git -C "$fork" rev-parse HEAD)
git -C "$fork" merge-base --is-ancestor "$upstream" "$head" ||
  die "the fork ref $fork_ref ($head) is not based on the upstream tag $tag ($upstream): rebase it (docs/gce-arm64.md)"
[[ $head != "$upstream" ]] ||
  die "the fork ref $fork_ref is the upstream tag $tag itself, without the arm64 GCE changes"
versionfile=$fork/sdk_container/.repo/manifests/version.txt
[[ -f $versionfile ]] || die "no $versionfile: is $fork a flatcar/scripts checkout?"
file_version=$(source "$versionfile"; printf '%s' "${FLATCAR_VERSION:-}")
sdk_version=$(source "$versionfile"; printf '%s' "${FLATCAR_SDK_VERSION:-}")
[[ $file_version == "$version" ]] || die "version.txt of the fork says $file_version, not $version"
valid_version "$sdk_version"
[[ -x $fork/run_sdk_container ]] || die "no run_sdk_container in $fork"
log "fork $fork_repository@$fork_ref $head, based on $tag ($upstream), SDK $sdk_version"

# --- free space: the SDK image, the board packages, the kernel build tree and the images
free_gb() { df -P -BG "$1" | awk 'NR == 2 { gsub("G", "", $4); print $4 }'; }
if [[ $min_free -gt 0 ]]; then
  have=$(free_gb "$fork")
  [[ $have -ge $min_free ]] || die "only ${have} GB free in $fork, need $min_free GB (MIN_FREE_GB)"
  if command -v docker >/dev/null 2>&1 && root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null) && [[ -d $root ]]; then
    have=$(free_gb "$root")
    [[ $have -ge $min_free ]] || die "only ${have} GB free in the Docker root $root, need $min_free GB (MIN_FREE_GB)"
  fi
fi

mkdir -p "$outdir" "$evidence"

# sdk ARGS...: a command in the SDK container (created on the first call, then reused).
# The repository's scripts are mounted read-only for the verification.
# run_sdk_container mounts the caller's ~/.gnupg, /run/user/<uid>/gnupg, the
# SSH agent socket and the gcloud credentials (and writes a boto file next to
# them) into the container when it finds them. On the shared runner none of
# the host's credentials belong in the build: HOME points into the run
# directory and the agent and credential variables are unset.
sdk_home=$fork/.sdk-home
mkdir -p "$sdk_home/.docker"
# The SDK refuses to run as root (it creates the build user from SDK_USER_ID,
# which run_sdk_container takes from `id -u`). The shared runner runs jobs as
# root and no account may be added to it, so as root the SDK steps run as a
# numeric uid:gid without a passwd entry (SDK_UID, default 4757:4757) that is
# in no group but docker (the Docker socket is all it needs; the container is
# privileged anyway, as in flatcar/scripts' own CI). The fork directory is
# owned by it, the docker client configuration is an empty one in .sdk-home
# (no credentials of root; the SDK image is public).
sdk_uid=${SDK_UID:-4757}
sdk_prefix=()
if [[ $(id -u) -eq 0 ]]; then
  [[ $sdk_uid =~ ^[1-9][0-9]{3,}$ ]] || die "invalid SDK_UID: $sdk_uid"
  need setpriv getent chown
  docker_gid=$(getent group docker | cut -d: -f3)
  [[ $docker_gid =~ ^[0-9]+$ ]] || die "no docker group: the SDK steps need access to the Docker socket"
  if getent passwd "$sdk_uid" >/dev/null || getent group "$sdk_uid" >/dev/null; then
    die "uid/gid $sdk_uid belongs to an account: set SDK_UID to an unused number"
  fi
  chown -R "$sdk_uid:$sdk_uid" "$fork"
  sdk_prefix=(setpriv --reuid="$sdk_uid" --regid="$sdk_uid" --groups="$docker_gid")
fi
# shellcheck disable=SC2086 # nice_cmd is a word list
sdk() {
  (cd "$fork" &&
    env -u SSH_AUTH_SOCK -u GNUPGHOME -u GOOGLE_APPLICATION_CREDENTIALS -u BOTO_PATH       "${sdk_prefix[@]}"       env DOCKER_CONFIG="$sdk_home/.docker" HOME="$sdk_home"       ./run_sdk_container -U -n "$container" -m "$REPO_ROOT:/mnt/host/images-repo:ro" $nice_cmd "$@")
}

# --- 2. build
log "== build_packages (binary cache for $version, kernel from source)"
sdk /mnt/host/images-repo/scripts/sdk-prepare-gce-arm64.sh
# The few source builds download distfiles from mirrors that sometimes fail:
# portage resumes where it stopped, so a failed run is repeated.
for attempt in 1 2 3; do
  sdk ./build_packages --board=$board && break
  [[ $attempt -lt 3 ]] || die "build_packages failed $attempt times"
  log "build_packages failed (attempt $attempt), retrying in 60 s"
  sleep 60
done
log "== build_image"
sdk ./build_image --board=$board --group="$channel" prod oem_sysext
# run_sdk_container mounts __build__/images at /mnt/host/source/src/build, and
# build_image writes to <that>/images/<board>/<group>-<version>-a1 with the
# relative symlink <group>-latest next to it.
images_link=$fork/__build__/images/images/$board/$channel-latest
[[ -L $images_link && -d $images_link ]] || die "build_image left no $images_link"
images=$(readlink -f "$images_link")
[[ $images == "$fork/__build__/images/images/$board/"* ]] || die "$images_link points outside the build directory: $images"
img_name=$(basename "$images")
in_sdk=/mnt/host/source/src/build/images/$board/$img_name
log "== image_to_vm --format=gce ($images)"
sdk ./image_to_vm.sh --board=$board --format=gce --from="$in_sdk"
# _write_gce_conf: flatcar_production_image.bin -> flatcar_production_gce.tar.gz
gce_tar=$images/flatcar_production_gce.tar.gz
[[ -s $gce_tar ]] || die "image_to_vm.sh left no $gce_tar"
[[ $(tar -tzf "$gce_tar") == disk.raw ]] || die "$gce_tar does not hold exactly disk.raw"

# --- 3. verify
vdir=$images/disk-verify
rm -rf "$vdir"; mkdir "$vdir"
tar -xzf "$gce_tar" -C "$vdir" disk.raw
log "== verify"
if [[ $runner == sdk ]]; then
  verify=(sdk /mnt/host/images-repo/scripts/verify-gce-arm64.sh "$in_sdk" "$in_sdk/disk-verify/disk.raw")
else
  verify=("$(dirname "${BASH_SOURCE[0]}")/verify-gce-arm64.sh" "$images" "$vdir/disk.raw")
fi
"${verify[@]}" 2>&1 | tee "$evidence/verify.log" || die "verification failed (see $evidence/verify.log)"

for f in "$images"/*_kernel_config.txt "$images"/*_realinitrd_contents.txt "$images"/oem-gce_contents.txt \
  "$images"/oem-gce_packages.txt "$images"/flatcar_production_image_packages.txt; do
  [[ -f $f ]] && cp "$f" "$evidence/"
done

# --- 4. package
src=$outdir/.source.json
jq -n --arg repository "$fork_repository" --arg ref "$fork_ref" --arg commit "$head" \
  --arg base_tag "$tag" --arg base_commit "$upstream" --arg sdk "$sdk_version" \
  '{repository: $repository, ref: $ref, commit: $commit, base_tag: $base_tag,
    base_commit: $base_commit, sdk_version: $sdk}' >"$src"
PACKAGE_REVISION=$revision PACKAGE_SOURCE_JSON=$src \
  "$(dirname "${BASH_SOURCE[0]}")/package.sh" "$vdir/disk.raw" gce "$channel" "$version" arm64 "$outdir" -
rm -f "$src"
rm -rf "$vdir"
log "built $(artifact_name gce "$channel" "$version" arm64 tar.gz "$revision") in $outdir"
