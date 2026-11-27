#!/usr/bin/env bash
# Build the iSCSI boot overlay initrd of an Oracle Cloud image, without root.
#
# usage: oci-ibft.sh IMAGE OUTDIR
#
# IMAGE is the raw disk of the official oraclecloud image. Writes
# OUTDIR/flatcar-ibft.cpio: an initrd that the kernel unpacks on top of its
# embedded one (docs/oraclecloud-iscsi.md). It replaces no file of the embedded
# initramfs but the module indexes: the kernel line says rdinit=/ibft-init, and
# an initrd left on the OEM partition by an older release never takes over (its
# first line runs the embedded /init unless the kernel version is the one baked in).
# It carries
# - /ibft-init: the embedded initramfs's minimal-init with
#   patches/minimal-init-ibft.patch applied (the build fails when the patch does
#   not apply: a new release changed minimal-init and the patch needs a look);
# - /usr/lib/ibft: iscsistart and the shared libraries it needs that the
#   embedded initramfs lacks, in a directory of their own;
# - the modules of DRIVERS (listed in /etc/ibft-modules) with their
#   dependencies, resolved from USR-A;
# - regenerated modules.* indexes for the embedded modules plus the new ones
#   (the build fails when a module of the embedded initramfs differs from USR-A's);
# - an iscsid.conf with a long replacement_timeout, and the files of overlay/.
#
# Everything is read without mounting: vmlinuz-a from the ESP with mtools, USR-A
# with `btrfs restore`. The archive is newc, root-owned, sorted and with fixed
# mtimes, so the same image gives the same bytes.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The network drivers of the machines that boot from iSCSI: BM.Standard.E2
# bnxt_en, the newer shapes mlx5_core, and virtio_net for QEMU guests (the boot
# test), plus on amd64 the firmware table reader iscsi_ibft. Flatcar's arm64
# kernel has no iscsi_ibft (CONFIG_ISCSI_IBFT is unset): the init reads the raw
# ACPI table there. The init loads the modules from /etc/ibft-modules.
DRIVERS=(bnxt_en mlx5_core virtio_net)
# replacement_timeout in seconds: I/O queues this long when the session drops.
REPLACEMENT_TIMEOUT=6000

[[ $# -eq 2 ]] || die "usage: oci-ibft.sh IMAGE OUTDIR"
image=$1 outdir=$2
[[ -f $image ]] || die "no such image: $image"
need sfdisk jq mcopy btrfs xz cpio depmod modinfo readelf patch od tail head grep sed awk cmp realpath paste install dd touch
mkdir -p "$outdir"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
umask 022

read -r esp_start usr_start usr_size ssize < <(sfdisk --json "$image" | jq -r '
  .partitiontable as $t
  | ([$t.partitions[]? | select(.name == "EFI-SYSTEM")] | first) as $e
  | ([$t.partitions[]? | select(.name == "USR-A")] | first) as $u
  | "\($e.start) \($u.start) \($u.size) \($t.sectorsize // 512)"') || die "$image has no EFI-SYSTEM and USR-A partitions"
[[ $esp_start =~ ^[0-9]+$ && $usr_start =~ ^[0-9]+$ ]] || die "$image has no EFI-SYSTEM and USR-A partitions"

# --- the kernel's embedded initramfs -----------------------------------------

# is_arm64_image KERNEL: an arm64 Image ("ARM\x64" magic at offset 56), else a bzImage.
is_arm64_image() { [[ $(od -An -tx1 -j 56 -N4 "$1" | tr -d ' ') == 41524d64 ]]; }

# unpack_initramfs VMLINUZ DIR: unpack the xz-compressed cpio that the kernel
# image embeds into DIR. On amd64 the bzImage payload is the compressed vmlinux
# (offset and length in the setup header); on arm64 the image is the plain,
# uncompressed kernel ("ARM\x64" magic at offset 56). The initramfs is the xz
# stream inside it that decompresses to a cpio archive.
unpack_initramfs() {
  local bz=$1 dir=$2 sects off len start magic vmlinux=$tmp/vmlinux o offsets
  if is_arm64_image "$bz"; then
    vmlinux=$bz
  else
    sects=$(od -An -tu1 -j $((0x1f1)) -N1 "$bz" | tr -d ' ')
    off=$(od -An -tu4 -j $((0x248)) -N4 "$bz" | tr -d ' ')
    len=$(od -An -tu4 -j $((0x24c)) -N4 "$bz" | tr -d ' ')
    start=$(( ((sects == 0 ? 4 : sects) + 1) * 512 + off ))
    magic=$(od -An -tx1 -j "$start" -N4 "$bz" | tr -d ' ')
    case $magic in
      fd377a58) tail -c +$((start + 1)) "$bz" | head -c "$len" | xz -dc --single-stream >"$vmlinux" ;;
      28b52ffd) need zstd; tail -c +$((start + 1)) "$bz" | head -c "$len" | zstd -dc >"$vmlinux" ;;
      1f8b*) tail -c +$((start + 1)) "$bz" | head -c "$len" | gzip -dc >"$vmlinux" ;;
      *) die "unknown kernel payload compression ($magic)" ;;
    esac
  fi
  mkdir "$dir"
  mapfile -t offsets < <(LC_ALL=C grep -obUaP '\xfd7zXZ\x00' "$vmlinux" | cut -d: -f1)
  for o in "${offsets[@]}"; do
    if [[ $(tail -c +$((o + 1)) "$vmlinux" | xz -dc --single-stream 2>/dev/null | head -c 6 || true) == 070701 ]]; then
      # dev/ holds device nodes, which a user cannot create and nothing here needs.
      (cd "$dir" && tail -c +$((o + 1)) "$vmlinux" | xz -dc --single-stream 2>/dev/null | cpio -idm --quiet -f 'dev/*') || true
      [[ -x $dir/init ]] || die "unpacking the embedded initramfs failed"
      return
    fi
  done
  die "no xz-compressed initramfs found in the kernel image"
}

esp=$image@@$((esp_start * ssize))
MTOOLS_SKIP_CHECK=1 mcopy -i "$esp" ::flatcar/vmlinuz-a "$tmp/vmlinuz-a" 2>/dev/null || die "no flatcar/vmlinuz-a in the EFI-SYSTEM partition of $image"
ird=$tmp/ird
is_arm64_image "$tmp/vmlinuz-a" || DRIVERS=(iscsi_ibft "${DRIVERS[@]}")
unpack_initramfs "$tmp/vmlinuz-a" "$ird"
rm -f "$tmp/vmlinux"

# --- USR-A, read without mounting --------------------------------------------

usr_part=$tmp/usr-a.part
dd if="$image" of="$usr_part" iflag=skip_bytes,count_bytes skip=$((usr_start * ssize)) count=$((usr_size * ssize)) bs=4M conv=sparse status=none

# usr_restore DEST PATH...: restore PATHs (relative to /usr) from USR-A into
# DEST, and what the symlinks among them point to. `btrfs restore` takes a
# regular expression over whole paths: every path and its parent directories.
usr_restore() {
  local dest=$1 p t
  local -a todo=("${@:2}") next
  local -A seen=()
  mkdir -p "$dest"
  while ((${#todo[@]})); do
    local -A want=()
    for p in "${todo[@]}"; do
      seen[$p]=1
      while [[ $p != . ]]; do want[$p]=1; p=$(dirname "$p"); done
    done
    local re
    re="^/($(printf '%s\n' "${!want[@]}" | sed 's/[][\.*^$+?(){}|]/\\&/g' | paste -sd '|'))\$"
    btrfs restore -S --path-regex "$re" "$usr_part" "$dest" >/dev/null 2>&1 || die "btrfs restore from USR-A failed"
    next=()
    for p in "${todo[@]}"; do
      [[ -e $dest/$p || -L $dest/$p ]] || die "$p is not in USR-A of $image"
      if [[ -L $dest/$p ]]; then
        t=$(readlink "$dest/$p")
        [[ $t == /* ]] && die "$p links to the absolute path $t"
        t=$(realpath -ms --relative-to=/ "/$(dirname "$p")/$t")
        [[ -n ${seen[$t]:-} ]] || next+=("$t")
      fi
    done
    todo=("${next[@]}")
  done
}

# The kernel version is the one of the embedded initramfs's modules directory;
# restoring USR-A's modules.dep below fails when USR-A holds another one.
kver=$(find "$ird/usr/lib/modules" -mindepth 1 -maxdepth 1 -printf '%f\n')
[[ -n $kver && $kver != *$'\n'* ]] || die "the embedded initramfs holds no, or more than one, kernel modules directory"
log "kernel $kver"
usr_dir=$tmp/usr
moddir=lib/modules/$kver
usr_restore "$usr_dir" "$moddir/modules.dep" "$moddir/modules.builtin" "$moddir/modules.builtin.modinfo" "$moddir/modules.order"

# --- modules -----------------------------------------------------------------

# The modules of DRIVERS and their dependencies, from USR-A's modules.dep
# (every line lists the complete dependency list of its module).
wanted_list=$(awk -F': *' -v drivers="${DRIVERS[*]}" '
  BEGIN { n = split(drivers, d, " "); for (i = 1; i <= n; i++) want[d[i]] = 1 }
  { name = $1; sub(".*/", "", name); sub(/\.ko.*/, "", name); gsub("-", "_", name)
    if (name in want) { found[name] = 1; print $1; m = split($2, dep, " "); for (i = 1; i <= m; i++) print dep[i] } }
  END { for (k in want) if (!(k in found)) { print "missing " k > "/dev/stderr"; exit 1 } }' \
  "$usr_dir/$moddir/modules.dep" | sort -u) || die "a driver module is not in USR-A"
mapfile -t wanted <<<"$wanted_list"

# Modules the embedded initramfs has stay there; they must be USR-A's own
# files, or the shared modules.* indexes could not be trusted.
mapfile -t embedded < <(cd "$ird/usr/lib/modules/$kver" && find kernel -name '*.ko' | sort)
declare -A have=()
for m in "${embedded[@]}"; do have[$m.xz]=1; done
embedded_xz=("${embedded[@]/%/.xz}")
new=()
for m in "${wanted[@]}"; do [[ -n ${have[$m]:-} ]] || new+=("$m"); done
[[ ${#new[@]} -gt 0 ]] || die "no module to add: unexpected for $kver"
usr_restore "$usr_dir" "${embedded_xz[@]/#/$moddir/}" "${new[@]/#/$moddir/}"
for m in "${embedded[@]}"; do
  cmp -s <(xz -dc "$usr_dir/$moddir/$m.xz") "$ird/usr/lib/modules/$kver/$m" || die "module $m of the embedded initramfs differs from USR-A's"
done

ov=$tmp/ov
mkdir -p "$ov/usr/lib/modules/$kver" "$ov/usr/lib/ibft/lib64" "$ov/etc/iscsi"
for m in "${new[@]}"; do
  mkdir -p "$ov/usr/lib/modules/$kver/$(dirname "$m")"
  xz -dc "$usr_dir/$moddir/$m" >"$ov/usr/lib/modules/$kver/${m%.xz}"
done
log "modules added: $(printf '%s ' "${new[@]##*/}")"

# modules.*: depmod over the embedded and the new modules together.
dep=$tmp/dep/lib/modules/$kver
mkdir -p "$dep"
cp -a "$ird/usr/lib/modules/$kver/kernel" "$dep/"
cp -a "$ov/usr/lib/modules/$kver/kernel/." "$dep/kernel/"
cp "$usr_dir/$moddir"/modules.{builtin,builtin.modinfo,order} "$dep/"
depmod -b "$tmp/dep" "$kver"
for f in $(cd "$ird/usr/lib/modules/$kver" && find . -maxdepth 1 -name 'modules.*' -printf '%f\n'); do
  if [[ -f $dep/$f ]]; then
    cp "$dep/$f" "$ov/usr/lib/modules/$kver/$f"
  elif [[ $f == modules.weakdep ]]; then
    # kmod before 32 does not write it: the embedded file stays, which is right
    # as long as none of the added modules has a weak dependency.
    [[ -z $(find "$ov/usr/lib/modules/$kver/kernel" -name '*.ko' -exec modinfo -F weakdep {} +) ]] || die "an added module has weak dependencies and depmod cannot write modules.weakdep"
  else
    die "depmod did not write $f"
  fi
done

# --- iscsistart and the libraries the embedded initramfs lacks ---------------

bins=$tmp/bins
usr_restore "$bins" bin/iscsistart
install -m 0755 "$bins/bin/iscsistart" "$ov/usr/lib/ibft/iscsistart"
libs=$tmp/libs
queue=("$bins/bin/iscsistart")
declare -A seen_lib=()
while ((${#queue[@]})); do
  f=${queue[0]}
  queue=("${queue[@]:1}")
  for so in $(readelf -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
    if [[ -e $ird/usr/lib64/$so || -n ${seen_lib[$so]:-} ]]; then continue; fi
    seen_lib[$so]=1
    usr_restore "$libs" "lib64/$so"
    queue+=("$libs/lib64/$so")
  done
done
if [[ -d $libs/lib64 ]]; then
  cp -a "$libs/lib64/." "$ov/usr/lib/ibft/lib64/"
  find "$ov/usr/lib/ibft/lib64" -type f -exec chmod 0755 {} +
fi
log "libraries added: ${!seen_lib[*]}"

# --- iscsid.conf, /ibft-init, static files ----------------------------------------

usr_restore "$tmp/conf" share/iscsi/iscsid.conf
sed "s/^node.session.timeo.replacement_timeout = .*/node.session.timeo.replacement_timeout = $REPLACEMENT_TIMEOUT/" \
  "$tmp/conf/share/iscsi/iscsid.conf" >"$ov/etc/iscsi/iscsid.conf"
grep -qx "node.session.timeo.replacement_timeout = $REPLACEMENT_TIMEOUT" "$ov/etc/iscsi/iscsid.conf" ||
  die "iscsid.conf in USR-A has no replacement_timeout line to set"

printf '%s\n' "${DRIVERS[@]}" >"$ov/etc/ibft-modules"
cp "$ird/init" "$tmp/init"
patch --fuzz=0 --no-backup-if-mismatch -r - -s "$tmp/init" "$REPO_ROOT/patches/minimal-init-ibft.patch" ||
  die "patches/minimal-init-ibft.patch does not apply to this release's minimal-init: it changed upstream, adapt the patch"
# The guard is the second line: busybox is the only tool there is at that point.
# shellcheck disable=SC2016
{ head -n 1 "$tmp/init"; printf '[ "$(busybox uname -r)" = "%s" ] || exec /init\n' "$kver"; tail -n +2 "$tmp/init"; } >"$ov/ibft-init"
chmod 0755 "$ov/ibft-init"

cp -a "$REPO_ROOT/overlay/." "$ov/"

# --- the archive ---------------------------------------------------------------

# Modes: directories 0755, files 0755 when executable and else 0644. Mtimes are
# fixed and the names sorted. `--owner` makes every entry root's.
find "$ov" -type d -exec chmod 0755 {} +
find "$ov" -type f -perm -u+x -exec chmod 0755 {} +
find "$ov" -type f ! -perm -u+x -exec chmod 0644 {} +
find "$ov" -exec touch -h -d @0 {} +
(cd "$ov" && find . -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --reproducible --quiet) >"$outdir/flatcar-ibft.cpio.part"
mv "$outdir/flatcar-ibft.cpio.part" "$outdir/flatcar-ibft.cpio"
log "wrote $outdir/flatcar-ibft.cpio ($(stat -c %s "$outdir/flatcar-ibft.cpio") bytes)"
