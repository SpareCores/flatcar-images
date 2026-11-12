#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2012,SC2153
# The GCE arm64 pipeline (build-gce-arm64.yml) without Docker, the SDK or the
# network: a throwaway "fork" repository with a stub run_sdk_container that
# writes the files the real build_image / image_to_vm.sh write, then
# build-gce-arm64.sh, verify-gce-arm64.sh, release-gce-arm64.sh and
# cleanup-gce-arm64.sh on that.
source "$(dirname "$0")/lib.sh"
require_tools sgdisk sfdisk jq mkfs.btrfs btrfs fakeroot git tar gzip blkid sha256sum truncate
source "$SCRIPTS/lib.sh"

echo "-- input validators"
assert_ok "fork repository of the organisation" bash -c 'source "$1"; valid_fork_repository SpareCores/flatcar-scripts' _ "$SCRIPTS/lib.sh"
assert_fails "fork repository of another owner" bash -c 'source "$1"; valid_fork_repository evil/flatcar-scripts' _ "$SCRIPTS/lib.sh"
assert_fails "fork repository with a path trick" bash -c 'source "$1"; valid_fork_repository "SpareCores/../x"' _ "$SCRIPTS/lib.sh"
assert_ok "fork ref" bash -c 'source "$1"; valid_fork_ref gce-arm64; valid_fork_ref release/gce.1' _ "$SCRIPTS/lib.sh"
assert_fails "fork ref with a leading dash" bash -c 'source "$1"; valid_fork_ref -x' _ "$SCRIPTS/lib.sh"
assert_fails "fork ref with a space" bash -c 'source "$1"; valid_fork_ref "a b"' _ "$SCRIPTS/lib.sh"
assert_fails "fork ref with dot dot" bash -c 'source "$1"; valid_fork_ref "a..b"' _ "$SCRIPTS/lib.sh"
assert_fails "fork ref with a command substitution" bash -c 'source "$1"; valid_fork_ref "a\$(id)"' _ "$SCRIPTS/lib.sh"

# --- fixtures
# make_gce_disk PATH SYSEXT_FILE CONSOLE_LINE: a Flatcar-like disk whose OEM
# partition (btrfs) holds grub.cfg, sysext/oem-gce-9999.0.1.raw and the active marker.
make_gce_disk() {
  local disk=$1 sysext=$2 console=$3 root=$T/gceoem s e fsimg=$T/gceoem.fs
  make_disk "$disk" btrfs
  rm -rf "$root"; mkdir -p "$root/sysext"
  printf '# test\nset oem_id="gce"\n%s\n' "$console" >"$root/grub.cfg"
  cp "$sysext" "$root/sysext/oem-gce-9999.0.1.raw"
  touch "$root/sysext/active-oem-gce"
  read -r s e < <(oem_range "$disk")
  rm -f "$fsimg"; truncate -s $((e - s)) "$fsimg"
  fakeroot -- mkfs.btrfs -q -f -M -O block-group-tree -L OEM --rootdir "$root" "$fsimg" >/dev/null
  dd if="$fsimg" of="$disk" bs=1M seek=$((s / 1048576)) conv=notrunc status=none
}
head -c 300000 /dev/urandom >"$T/oem-gce.raw"
make_gce_disk "$T/good.disk" "$T/oem-gce.raw" 'set linux_console="console=tty0 console=ttyAMA0,115200n8"'
make_gce_disk "$T/noconsole.disk" "$T/oem-gce.raw" 'set linux_console="console=ttyS0,115200n8"'
head -c 300000 /dev/urandom >"$T/other.raw"
make_gce_disk "$T/othersysext.disk" "$T/other.raw" 'set linux_console="console=tty0 console=ttyAMA0,115200n8"'

# The stub SDK entry point of the fork: what run_sdk_container does, minus Docker.
STUB=$T/run_sdk_container.stub
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
echo "$*" >>"${STUB_LOG:?}"
while [[ $# -gt 0 ]]; do
  case $1 in
    -U) shift ;;
    -n | -m | -x | -V | -v | -a) shift 2 ;;
    *) break ;;
  esac
done
while [[ $# -gt 0 && $1 != ./* && $1 != /* ]]; do shift; done # nice/ionice prefix
cmd=$1; shift
# Paths as the container sees them.
tr_path() { local p=${1/#\/mnt\/host\/source\/src\/build/$here/__build__}; printf '%s' "${p/#\/mnt\/host\/images-repo/$STUB_REPO}"; }
images=$here/__build__/images/arm64-usr
case ${cmd##*/} in
  build_packages) [[ $* == --board=arm64-usr ]] ;;
  build_image)
    group=
    for a; do [[ $a == --group=* ]] && group=${a#--group=}; done
    d=$images/$group-9999.0.1-a1
    mkdir -p "$d"
    ln -sfn "$group-9999.0.1-a1" "$images/$group-latest"
    { echo 'CONFIG_FOO=y'; [[ -n ${STUB_NO_GVE:-} ]] || echo 'CONFIG_GVE=m'; } >"$d/flatcar_production_image_kernel_config.txt"
    { echo 'drwxr-xr-x ./usr/lib/modules/6.12.114-flatcar/kernel/drivers/net/ethernet/google/gve'
      [[ -n ${STUB_NO_GVE:-} ]] || echo '-rw-r--r-- 1 root root 123 ./usr/lib/modules/6.12.114-flatcar/kernel/drivers/net/ethernet/google/gve/gve.ko'
    } >"$d/flatcar_production_image_realinitrd_contents.txt"
    { echo './usr/lib/udev/rules.d/65-gce-disk-naming.rules'; echo './usr/bin/google_nvme_id'; } >"$d/oem-gce_contents.txt"
    echo 'sys-kernel/coreos-kernel-6.12.114-r1::coreos-overlay' >"$d/flatcar_production_image_packages.txt"
    cp "$STUB_OEM_SYSEXT" "$d/oem-gce.raw"
    ;;
  image_to_vm.sh)
    from=
    for a; do [[ $a == --from=* ]] && from=$(tr_path "${a#--from=}"); done
    [[ -d $from ]]
    w=$(mktemp -d); cp "$STUB_DISK" "$w/disk.raw"
    tar -czf "$from/flatcar_production_gce_image.tar.gz" -C "$w" disk.raw; rm -rf "$w"
    ;;
  verify-gce-arm64.sh)
    exec "$(tr_path "$cmd")" "$(tr_path "$1")" "$(tr_path "$2")"
    ;;
  *) echo "stub: unexpected command $cmd" >&2; exit 2 ;;
esac
STUBEOF

g() { git -C "$FORK" -c user.name=t -c user.email=t@example.test -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
mkfork() { # DIR: a fork with the upstream tag stable-9999.0.1 and one commit on top
  FORK=$1
  mkdir -p "$FORK/sdk_container/.repo/manifests"
  printf 'FLATCAR_VERSION=9999.0.1\nFLATCAR_VERSION_ID=9999.0.1\nFLATCAR_BUILD_ID=""\nFLATCAR_SDK_VERSION=9998.0.0\n' >"$FORK/sdk_container/.repo/manifests/version.txt"
  cp "$STUB" "$FORK/run_sdk_container"; chmod +x "$FORK/run_sdk_container"
  git -C "$FORK" init -q -b main
  g add -A; g commit -q -m "New version: stable-9999.0.1"; g tag stable-9999.0.1
  echo patched >"$FORK/patch.txt"; g add -A; g commit -q -m "GCE arm64"
}
export STUB_REPO=$ROOT STUB_DISK=$T/good.disk STUB_OEM_SYSEXT=$T/oem-gce.raw MIN_FREE_GB=0
export FORK_REPOSITORY=SpareCores/flatcar-scripts FORK_REF=gce-arm64

echo "-- build"
mkfork "$T/fork"
export STUB_LOG=$T/sdk.log
build() { FORK_DIR=$1 OUTDIR=$2 CONTAINER=flatcar-gce-arm64-test1 "${@:3}" "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1 "${REV:-}"; }
head=$(git -C "$T/fork" rev-parse HEAD)
: >"$STUB_LOG"
assert_ok "builds with the default (SDK) verification" env FORK_DIR="$T/fork" OUTDIR="$T/out" CONTAINER=flatcar-gce-arm64-test1 "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1
art=flatcar-gce-stable-9999.0.1-arm64.tar.gz
assert_ok "artifact and meta exist" test -s "$T/out/$art" -a -s "$T/out/$art.meta.json"
assert_eq "no stray files in the output directory" "$art $art.meta.json" "$(ls "$T/out" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "meta records the fork" "SpareCores/flatcar-scripts gce-arm64 $head stable-9999.0.1" \
  "$(jq -r '"\(.source.repository) \(.source.ref) \(.source.commit) \(.source.base_tag)"' "$T/out/$art.meta.json")"
assert_eq "meta: vendor, oem id, arch, no source_image" "gce gce arm64 false" "$(jq -r '"\(.vendor) \(.oem_id) \(.arch) \(has("source_image"))"' "$T/out/$art.meta.json")"
assert_eq "SDK version is recorded" "9998.0.0" "$(jq -r .source.sdk_version "$T/out/$art.meta.json")"
assert_eq "tar holds only disk.raw" "disk.raw" "$(tar -tzf "$T/out/$art")"
mkdir "$T/x"; tar -xzf "$T/out/$art" -C "$T/x"
assert_eq "disk.raw is padded to a whole GiB" "0" "$(($(stat -c %s "$T/x/disk.raw") % 1073741824))"
assert_ok "disk.raw starts with the built disk" cmp -n 67108864 "$T/good.disk" "$T/x/disk.raw"
assert_eq "oldgnu tar" "ustar " "$(gzip -dc "$T/out/$art" | dd bs=1 skip=257 count=6 status=none)"
assert_eq "SDK commands in order, with -U and the container" \
  "-U -n flatcar-gce-arm64-test1 ./build_packages --board=arm64-usr
-U -n flatcar-gce-arm64-test1 ./build_image --board=arm64-usr --group=stable prod oem_sysext
-U -n flatcar-gce-arm64-test1 ./image_to_vm.sh --board=arm64-usr --format=gce --from=/mnt/host/source/src/build/images/arm64-usr/stable-9999.0.1-a1
-U -n flatcar-gce-arm64-test1 /mnt/host/images-repo/scripts/verify-gce-arm64.sh /mnt/host/source/src/build/images/arm64-usr/stable-9999.0.1-a1 /mnt/host/source/src/build/images/arm64-usr/stable-9999.0.1-a1/disk-verify/disk.raw" \
  "$(sed -E 's/ -m [^ ]+//; s/ (nice -n 10 ionice -c 2 -n 7)//' "$STUB_LOG")"
assert_ok "commands run niced by default" grep -q ' nice -n 10 ionice -c 2 -n 7 ./build_packages' "$STUB_LOG"
assert_ok "the repository is mounted read-only for the verification" grep -q -- "-m $ROOT:/mnt/host/images-repo:ro" "$STUB_LOG"
assert_ok "evidence: kernel config" grep -q '^CONFIG_GVE=m' "$T/out.evidence/flatcar_production_image_kernel_config.txt"
assert_ok "evidence: initrd contents and verify log" test -s "$T/out.evidence/flatcar_production_image_realinitrd_contents.txt" -a -s "$T/out.evidence/verify.log"
assert_ok "evidence: package list" grep -q 'coreos-kernel-6.12.114-r1' "$T/out.evidence/flatcar_production_image_packages.txt"
assert_fails "the extracted disk is removed from the build directory" test -e "$T/fork/__build__/images/arm64-usr/stable-9999.0.1-a1/disk-verify"

echo "-- build with host verification, revision and no nice"
: >"$STUB_LOG"
assert_ok "host runner, revision r2" env FORK_DIR="$T/fork" OUTDIR="$T/out2" CONTAINER=flatcar-gce-arm64-test1 VERIFY_RUNNER=host NICE_CMD= \
  "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1 r2
assert_ok "revision in the artifact name" test -s "$T/out2/flatcar-gce-stable-9999.0.1-r2-arm64.tar.gz"
assert_eq "no verify call in the SDK for the host runner, no nice" "3 0" "$(wc -l <"$STUB_LOG") $(grep -c 'nice\|verify-gce' "$STUB_LOG")"

echo "-- build refuses a bad fork"
export VERIFY_RUNNER=host
mkfork "$T/fork-notag"; g tag -d stable-9999.0.1 >/dev/null
assert_fails_with "no upstream tag" "no tag stable-9999.0.1" env FORK_DIR="$T/fork-notag" OUTDIR="$T/o1" "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1
mkfork "$T/fork-stock"; g reset -q --hard stable-9999.0.1
assert_fails_with "fork ref equal to the upstream tag" "itself" env FORK_DIR="$T/fork-stock" OUTDIR="$T/o2" "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1
mkfork "$T/fork-other"; g checkout -q --orphan unrelated; echo x >"$T/fork-other/y"; g add -A; g commit -q -m unrelated
assert_fails_with "fork ref not based on the upstream tag" "not based on the upstream tag" env FORK_DIR="$T/fork-other" OUTDIR="$T/o3" "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1
mkfork "$T/fork-v2"; g tag stable-9999.0.2 stable-9999.0.1
assert_fails_with "version.txt of another version" "says 9999.0.1, not 9999.0.2" env FORK_DIR="$T/fork-v2" OUTDIR="$T/o4" "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.2
mkfork "$T/fork-lts"; g tag lts-9999.0.1 stable-9999.0.1
assert_ok "channel decides the upstream tag and the group" env FORK_DIR="$T/fork-lts" OUTDIR="$T/o5" "$SCRIPTS/build-gce-arm64.sh" lts 9999.0.1
assert_ok "lts group image directory" test -d "$T/fork-lts/__build__/images/arm64-usr/lts-9999.0.1-a1"
assert_fails_with "not enough free space" "GB free" env FORK_DIR="$T/fork" OUTDIR="$T/o6" MIN_FREE_GB=99999999 "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1
assert_fails_with "fork repository of another owner" "invalid fork repository" env FORK_DIR="$T/fork" OUTDIR="$T/o7" FORK_REPOSITORY=evil/x "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1
assert_fails_with "bad container name" "invalid container name" env FORK_DIR="$T/fork" OUTDIR="$T/o8" CONTAINER='x;y' "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1
assert_fails_with "no fork directory" "FORK_DIR" env -u FORK_DIR "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1
assert_fails "bad revision" env FORK_DIR="$T/fork" OUTDIR="$T/o9" "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1 x
assert_fails_with "a kernel without gVNIC fails the verification and leaves no artifact" "CONFIG_GVE=m" env STUB_NO_GVE=1 FORK_DIR="$T/fork" OUTDIR="$T/o10" "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1
assert_fails "no artifact after a failed verification" test -e "$T/o10/$art"
assert_fails_with "an image without the arm64 console fails" "ttyAMA0" env STUB_DISK="$T/noconsole.disk" FORK_DIR="$T/fork" OUTDIR="$T/o11" "$SCRIPTS/build-gce-arm64.sh" stable 9999.0.1
unset VERIFY_RUNNER

echo "-- verify-gce-arm64.sh"
good=$T/fork/__build__/images/arm64-usr/stable-9999.0.1-a1
assert_ok "good image passes" "$SCRIPTS/verify-gce-arm64.sh" "$good" "$T/good.disk"
out=$("$SCRIPTS/verify-gce-arm64.sh" "$good" "$T/good.disk" 2>&1)
assert_eq "all eight checks reported" "8" "$(grep -c '^ok:' <<<"$out")"
cp -r "$good" "$T/v2"; sed -i '/gve.ko/d' "$T/v2/flatcar_production_image_realinitrd_contents.txt"
assert_fails_with "initrd without gve.ko" "gve.ko is not in the initrd" "$SCRIPTS/verify-gce-arm64.sh" "$T/v2" "$T/good.disk"
cp -r "$good" "$T/v3"; : >"$T/v3/oem-gce_contents.txt"
assert_fails_with "OEM sysext without the udev rules" "no 65-gce-disk-naming.rules" "$SCRIPTS/verify-gce-arm64.sh" "$T/v3" "$T/good.disk"
assert_fails_with "OEM sysext without google_nvme_id" "no google_nvme_id" "$SCRIPTS/verify-gce-arm64.sh" "$T/v3" "$T/good.disk"
assert_fails_with "sysext on the disk is not the built one" "differs from the built" "$SCRIPTS/verify-gce-arm64.sh" "$good" "$T/othersysext.disk"
assert_fails_with "x86 console only" "no ttyAMA0" "$SCRIPTS/verify-gce-arm64.sh" "$good" "$T/noconsole.disk"
cp "$T/good.disk" "$T/v4.disk"; sgdisk -c 6:NOTOEM "$T/v4.disk" >/dev/null
assert_fails_with "disk without an OEM partition" "no GPT with exactly one partition named OEM" "$SCRIPTS/verify-gce-arm64.sh" "$good" "$T/v4.disk"
assert_fails "missing image directory" "$SCRIPTS/verify-gce-arm64.sh" "$T/nodir" "$T/good.disk"

echo "-- release-gce-arm64.sh assemble"
# The release as build.yml made it: three other artifacts and an old, OEM-patched gce arm64 one.
rel=$T/rel; mkdir "$rel"
echo '{"url":"u","sha512":"s5","sha256":"s2","size":1,"signed_by":"F"}' >"$T/src.json"
head -c 1000 /dev/urandom >"$T/disk.img"
for spec in "vultr amd64" "aliyun arm64"; do
  read -r vendor arch <<<"$spec"
  "$SCRIPTS/package.sh" "$T/disk.img" "$vendor" stable 9999.0.1 "$arch" "$rel" "$T/src.json" >/dev/null 2>&1
done
cp "$T/good.disk" "$T/old.disk"
"$SCRIPTS/package.sh" "$T/old.disk" gce stable 9999.0.1 arm64 "$rel" "$T/src.json" >/dev/null 2>&1
"$SCRIPTS/manifest.sh" "$rel" stable 9999.0.1 >/dev/null 2>&1
old_gce_sha=$(jq -r '.artifacts[] | select(.vendor=="gce") | .sha256' "$rel/manifest.json")
assert_ok "the old release lists a gce artifact" test -n "$old_gce_sha"
cp "$rel/manifest.json" "$T/existing-manifest.json"
assert_eq "assemble replaces the artifact of the same name" "replaced" \
  "$("$SCRIPTS/release-gce-arm64.sh" assemble "$T/out" "$T/asm" stable 9999.0.1 "" "$T/existing-manifest.json" 2>/dev/null)"
assert_eq "output holds the new artifact, manifest and sums only" "SHA256SUMS flatcar-gce-stable-9999.0.1-arm64.tar.gz manifest.json" "$(ls "$T/asm" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "manifest lists all four artifacts" "flatcar-aliyun-stable-9999.0.1-arm64.img.gz flatcar-aliyun-stable-9999.0.1-arm64.qcow2 flatcar-gce-stable-9999.0.1-arm64.tar.gz flatcar-vultr-stable-9999.0.1-amd64.img.gz" \
  "$(jq -r '[.artifacts[].name] | join(" ")' "$T/asm/manifest.json")"
new_sha=$(sha256sum <"$T/asm/$art" | cut -d' ' -f1)
assert_eq "the gce entry is the new file" "$new_sha" "$(jq -r '.artifacts[] | select(.vendor=="gce") | .sha256' "$T/asm/manifest.json")"
assert_eq "and has the fork as its source" "$head" "$(jq -r '.artifacts[] | select(.vendor=="gce") | .source.commit' "$T/asm/manifest.json")"
assert_eq "other entries are unchanged (url included)" \
  "$(jq -S '.artifacts[] | select(.vendor=="vultr")' "$T/existing-manifest.json")" "$(jq -S '.artifacts[] | select(.vendor=="vultr")' "$T/asm/manifest.json")"
assert_eq "SHA256SUMS lists the four artifacts and the manifest" "5" "$(wc -l <"$T/asm/SHA256SUMS")"
assert_ok "SHA256SUMS is right for the files that are there" bash -c 'cd "$1" && sha256sum --check --ignore-missing --quiet SHA256SUMS' _ "$T/asm"
assert_ok "SHA256SUMS keeps the other artifacts' sums" grep -q "$(jq -r '.artifacts[] | select(.vendor=="vultr") | .sha256' "$T/existing-manifest.json")  flatcar-vultr-stable-9999.0.1-amd64.img.gz" "$T/asm/SHA256SUMS"
assert_fails "SHA256SUMS does not keep the old gce sum" grep -q "$old_gce_sha" "$T/asm/SHA256SUMS"
assert_eq "manifest tag" "stable-9999.0.1" "$(jq -r .tag "$T/asm/manifest.json")"
assert_eq "a new release is only the gce artifact" "added" \
  "$("$SCRIPTS/release-gce-arm64.sh" assemble "$T/out" "$T/asm2" stable 9999.0.1 2>/dev/null)"
assert_eq "its manifest lists one artifact" "1" "$(jq '.artifacts | length' "$T/asm2/manifest.json")"
assert_eq "assemble with a revision adds it to the tag and name" "added stable-9999.0.1-r2 flatcar-gce-stable-9999.0.1-r2-arm64.tar.gz" \
  "$("$SCRIPTS/release-gce-arm64.sh" assemble "$T/out2" "$T/asm3" stable 9999.0.1 r2 2>/dev/null) $(jq -r '"\(.tag) \(.artifacts[0].name)"' "$T/asm3/manifest.json")"
assert_fails_with "a non-empty output directory is refused" "not empty" "$SCRIPTS/release-gce-arm64.sh" assemble "$T/out" "$T/asm" stable 9999.0.1
assert_fails_with "the manifest of another release is refused" "not the manifest of release" "$SCRIPTS/release-gce-arm64.sh" assemble "$T/out2" "$T/asm4" stable 9999.0.1 r2 "$T/existing-manifest.json"
assert_fails_with "missing artifact" "no flatcar-gce" "$SCRIPTS/release-gce-arm64.sh" assemble "$T/rel" "$T/asm5" stable 9999.0.2
mkdir "$T/badmeta"; cp "$T/out/$art" "$T/badmeta/"
jq '.vendor = "vultr"' "$T/out/$art.meta.json" >"$T/badmeta/$art.meta.json"
assert_fails_with "a meta file that does not describe the gce artifact" "does not describe" "$SCRIPTS/release-gce-arm64.sh" assemble "$T/badmeta" "$T/asm6" stable 9999.0.1
assert_fails "unknown command" "$SCRIPTS/release-gce-arm64.sh" frob
assert_ok "verify.sh checks the merged release (sums only)" bash -c 'mkdir -p "$2" && cp "$1"/SHA256SUMS "$1"/manifest.json "$1"/flatcar-gce-* "$2"/ && VERIFY_SKIP_SIGNATURES=1 "$3" "$2"' _ "$T/asm" "$T/vfy" "$SCRIPTS/verify.sh"

echo "-- release-gce-arm64.sh notes"
printf 'Flatcar stable 9999.0.1: generic image.\n\n| table |\n' >"$T/old-notes.md"
notes=$("$SCRIPTS/release-gce-arm64.sh" notes "$T/asm/manifest.json" "$art" "$T/old-notes.md")
assert_ok "keeps the existing text" grep -q '^| table |$' <<<"$notes"
assert_ok "names the fork commit" grep -q "SpareCores/flatcar-scripts@${head:0:12}" <<<"$notes"
assert_ok "says why" grep -q 'no gVNIC driver' <<<"$notes"
assert_ok "warns about auto-updates" grep -q 'disable Flatcar auto-updates' <<<"$notes"
printf '%s\n' "$notes" >"$T/old-notes2.md"
notes2=$("$SCRIPTS/release-gce-arm64.sh" notes "$T/asm/manifest.json" "$art" "$T/old-notes2.md")
assert_eq "a rebuild replaces the section instead of repeating it" "1" "$(grep -c '^### Google Cloud arm64' <<<"$notes2")"
assert_ok "a new release gets the usual table" grep -q '^| Artifact |' <<<"$("$SCRIPTS/release-gce-arm64.sh" notes "$T/asm/manifest.json" "$art")"
assert_fails "an artifact without a fork source is refused" "$SCRIPTS/release-gce-arm64.sh" notes "$T/existing-manifest.json" flatcar-vultr-stable-9999.0.1-amd64.img.gz

echo "-- cleanup-gce-arm64.sh"
ws=$T/ws; mkdir -p "$ws/gce-arm64-123-1/__build__/images" "$ws/other"
echo x >"$ws/gce-arm64-123-1/__build__/images/f.raw"
cat >"$T/docker" <<'DEOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_DOCKER_LOG"
[[ $1 == container && $2 == inspect && ${STUB_NO_CONTAINER:-} == "" ]] || [[ $1 == rm ]]
DEOF
chmod +x "$T/docker"
export STUB_DOCKER_LOG=$T/docker.log WORK_ROOT=$ws DOCKER=$T/docker
: >"$STUB_DOCKER_LOG"
assert_ok "cleanup" env CONTAINER=flatcar-gce-arm64-123-1 "$SCRIPTS/cleanup-gce-arm64.sh" "$ws/gce-arm64-123-1"
assert_fails "the run directory is gone" test -e "$ws/gce-arm64-123-1"
assert_ok "other directories are untouched" test -d "$ws/other"
assert_eq "the container is removed with its volumes, nothing else is touched" "container inspect flatcar-gce-arm64-123-1
rm --force --volumes flatcar-gce-arm64-123-1" "$(cat "$STUB_DOCKER_LOG")"
assert_ok "cleanup of a run that never started is fine" env CONTAINER=flatcar-gce-arm64-123-1 STUB_NO_CONTAINER=1 "$SCRIPTS/cleanup-gce-arm64.sh" "$ws/gce-arm64-123-1"
mkdir -p "$ws/gce-arm64-9-1"
assert_fails_with "refuses a directory that is not a run directory" "not a gce-arm64" env CONTAINER=flatcar-gce-arm64-1 "$SCRIPTS/cleanup-gce-arm64.sh" "$ws/other"
assert_fails_with "refuses the workspace itself" "not a gce-arm64" env CONTAINER=flatcar-gce-arm64-1 "$SCRIPTS/cleanup-gce-arm64.sh" "$ws"
mkdir -p "$T/elsewhere/gce-arm64-5-1"
assert_fails_with "refuses a run-looking directory outside the work root" "not directly under" env CONTAINER=flatcar-gce-arm64-1 "$SCRIPTS/cleanup-gce-arm64.sh" "$T/elsewhere/gce-arm64-5-1"
assert_ok "and left it alone" test -d "$T/elsewhere/gce-arm64-5-1"
mkdir -p "$ws/gce-arm64-7-1/inner/gce-arm64-8-1"; ln -s "$T/elsewhere" "$ws/gce-arm64-6-1"
assert_fails_with "refuses a symlink to somewhere else" "not directly under" env CONTAINER=flatcar-gce-arm64-1 "$SCRIPTS/cleanup-gce-arm64.sh" "$ws/gce-arm64-6-1"
assert_fails_with "refuses a container name that is not ours" "invalid CONTAINER" env CONTAINER=other "$SCRIPTS/cleanup-gce-arm64.sh" "$ws/gce-arm64-9-1"
assert_fails_with "refuses an empty container name" "invalid CONTAINER" env -u CONTAINER "$SCRIPTS/cleanup-gce-arm64.sh" "$ws/gce-arm64-9-1"
finish
