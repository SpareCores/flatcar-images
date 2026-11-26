# Oracle Cloud bare metal: Flatcar on an iSCSI boot volume

The `oraclecloud-iscsi` image is the official Flatcar `oraclecloud` image with one extra initrd and one GRUB menu entry on the OEM partition. It boots on Oracle Cloud bare metal shapes (for example `BM.Standard.E2.64`) and, unchanged, on VM shapes. amd64 only.

Status: booted in QEMU via iSCSI/iBFT (the boot test below runs in CI). OCI bare metal live boot pending. Upstream issue: <https://github.com/flatcar/Flatcar/issues/2516>.

## The problem

A bare metal shape has no local disk. Its boot volume is an iSCSI target: the firmware (iPXE) logs in to it, loads GRUB from it, and describes the session in an ACPI table, the iBFT (iSCSI Boot Firmware Table). GRUB and the kernel start fine from there. Then Flatcar's early init, `minimal-init` in the kernel's embedded initramfs (busybox), waits for the `USR-A` partition to appear, and nothing in it logs in to the target again: the kernel has no iSCSI session, no disk shows up, and the boot ends in the emergency shell.

The stock initramfs lacks `iscsistart`, the `iscsi_ibft` module and the bare metal NICs' drivers as well. The dracut initrd that comes after it (`bootengine`, on `/usr`) can keep an iSCSI root, but only when it is told so on the kernel command line (`netroot=`, `rd.iscsi.firmware=1`), and those arguments break VMs: with a `netroot` the initrd waits for an iSCSI root that a VM does not have.

## What the image changes

Nothing outside the OEM partition. The build checks that, as for every image of this repository. On the OEM partition:

- `grub.cfg` gets a menu entry, the default, that runs Flatcar's own slot selection (`gptprio`) and kernel line unchanged, and adds the initrd only when the selected slot is the `USR-A` the image was built from (its partition UUID is read from the image):

  ```
  set ibft_oem="$oem"
  set default="flatcar-ibft"
  menuentry "Flatcar default" --id=flatcar-ibft --unrestricted {
      gptprio
      if [ "$usr_uuid" = "<USR-A partition UUID>" ]; then
          linux$suf $gptprio_kernel $gptprio_cmdline $linux_cmdline rdinit=/ibft-init
          initrd ($ibft_oem)/flatcar-ibft.cpio
      else
          linux$suf $gptprio_kernel $gptprio_cmdline $linux_cmdline
      fi
  }
  ```

  The only kernel argument added is `rdinit=/ibft-init`, and no hash is written down: GRUB adds `verity.usrhash` itself. Flatcar's own `fallback` stays. `$oem` is saved first because Flatcar's `grub.cfg` overwrites it after sourcing the OEM file.
- `flatcar-ibft.cpio` next to it. The kernel unpacks it on top of its embedded initramfs.
- The `sysext/` files of the OEM partition stay.

## What is in the initrd

`scripts/oci-ibft.sh` builds it from the image itself, without root and without mounting: `vmlinuz-a` is read from the ESP with mtools, `/usr` from USR-A with `btrfs restore`.

- `/ibft-init`: the embedded initramfs's `minimal-init` with `patches/minimal-init-ibft.patch` applied, started by `rdinit=/ibft-init`. Its first line runs the embedded `/init` instead unless `uname -r` is the kernel version baked in at build time, so a `flatcar-ibft.cpio` left on the OEM partition by an older release (after two updates the slot A kernel is newer than the initrd) never takes over. The build fails if the patch does not apply: a new release changed `minimal-init` and the patch needs a look.
- `/usr/lib/ibft/`: `iscsistart` and the shared libraries it needs that the embedded initramfs lacks (found by walking the ELF `NEEDED` entries; today `libopeniscsiusr` and `libkmod`), run with `LD_LIBRARY_PATH` set. No file of the embedded initramfs is replaced, except the `modules.*` indexes (below).
- The modules `iscsi_ibft`, `bnxt_en` (E2 shapes), `mlx5_core` (newer shapes) and `virtio_net` (QEMU, for the boot test), with the dependencies that the embedded initramfs lacks, resolved from USR-A's `modules.dep`. The list is in the script and is written into the initrd as `/etc/ibft-modules`. `modules.*` are regenerated with `depmod` over the embedded and the added modules; the build fails if a module of the embedded initramfs differs from USR-A's copy.
- `/etc/iscsi/iscsid.conf`: USR-A's, with `node.session.timeo.replacement_timeout = 6000`: during a connection drop I/O queues for up to 6000 s instead of failing after 120 s.
- The files of `overlay/`: `ibft-root-setup` and its unit, used in the dracut stage.

The archive is newc, root-owned, sorted and with fixed mtimes: the same image gives the same bytes.

## What happens at boot

Without an iBFT (a VM, or any machine without iSCSI boot) `iscsi_ibft_login` returns right after `modprobe iscsi_ibft` finds nothing, and the boot is the stock one apart from the unused initrd.

With an iBFT, the early init (it logs `iBFT: ...` lines to the kernel log, so they show on every console and in `dmesg`):

1. loads `iscsi_tcp` and the NIC drivers, waits up to 30 s for the NIC with the iBFT's MAC address (the name is not predictable), brings it up with `iscsistart -N`, adds a host route to the target through the iBFT gateway when the target is outside the NIC's subnet (it usually is: `169.254.0.2`);
2. logs in with `iscsistart -b`, up to three times, waiting up to 10 s each for the disk (a NIC can be slow to bring its link up), and goes on with the stock steps (dm-verity on USR-A, mount, switch to the dracut stage);
3. right before the switch, prepares the dracut stage in `/realinit`:
   - `/etc/cmdline.d/90-ibft.conf` with `rd.iscsi.firmware=1 rd.neednet=1 netroot=iscsi:`. dracut's `getarg` reads `/etc/cmdline.d` as well as `/proc/cmdline`, so its iscsi module, the `rd.neednet` network wait and the root session handling work as if the arguments were on the kernel command line. VMs never get the file.
   - `network-cleanup.service` masked. Its `ConditionKernelCommandLine=!netroot` reads only `/proc/cmdline`, which has no `netroot`, so unmasked it would flush the NIC's address at switch-root and the root disk with it.
   - `/etc/systemd/network/00-ibft.network` for the iBFT NIC (match by MAC, DHCP, `KeepConfiguration=yes`, `IgnoreCarrierLoss=yes`, the route to the target when it is off-subnet). The initrd's `yy-netroot.network` matches `KernelCommandLine=netroot` on `/proc/cmdline` only, so this file does its job in the initrd.
   - `ibft-root-setup.service`, which runs in the dracut stage after Ignition, before switch-root.

`ibft-root-setup` prepares the real root, in `/sysroot/etc`:

- `iscsi/initiatorname.iscsi` with the iBFT's initiator name (the target accepts only that one; `iscsi-init.service` would generate another);
- `iscsi/iscsid.conf` with the 6000 s timeout (replacing Flatcar's default copy);
- `systemd/network/00-ibft.network`, so that the running system keeps the NIC's address when `systemd-networkd` restarts or the lease is lost (the generic `zz-default.network` would drop it);
- `iscsid.service` and `iscsid.socket` enabled, so the root session is recovered after a drop. `iscsi.service` is not enabled: stopping it at shutdown would log the root session out too early.

It keeps files that exist (an Ignition config, a second boot), except Flatcar's default `iscsid.conf`. The dracut stage reads the initiator name from `/sys/firmware/ibft`, which is there because `iscsi_ibft` stays loaded; nothing else has to be handed over.

## Limits

- The initrd is loaded only when the `USR-A` slot boots. After an update Flatcar boots slot B, and the stock path cannot log in to iSCSI: a VM still boots, a bare metal node does not. Keep updates off on bare metal nodes (mask `update-engine` and `locksmithd`, as SCarpenter does) or replace nodes per Flatcar version.
- The OEM `grub.cfg` is read only with secure boot off, which is how the shapes boot today.
- Not built for LTS: its initramfs has no `minimal-init` yet.
- A stale initrd with the same kernel version but another module set would still replace the `modules.*` indexes; Flatcar changes the version string with every kernel build, so this is not expected.
- Only the NIC drivers above. Another bare metal family needs its driver in the list in `scripts/oci-ibft.sh`.
- Only the iBFT's first NIC and first target (`ethernet0`, `target0`), no CHAP, IPv4.
- amd64 only. arm64 bare metal (`BM.Standard.A1.160`) would need its own drivers and a boot test.
- A release whose `minimal-init` or modules differ fails the build until the patch or the recipe is adapted. When Flatcar ships iSCSI boot in its own images, this image is no longer built for the releases that carry it.

## Build and test

```sh
make build CHANNEL=stable VERSION=4757.2.3 ARCH=amd64 VENDOR=oraclecloud-iscsi
scripts/boot-test-iscsi.sh out/stable-4757.2.3/flatcar-oraclecloud-iscsi-stable-4757.2.3-amd64.qcow2
```

`config/platforms.json` names the source image (`flatcar_production_oraclecloud_image.img`, a qcow2 file; verified like the generic image, against the signed `DIGESTS.asc`), turns the overlay on (`ibft_overlay`) and holds the GRUB lines.

`make test` covers what needs no boot: `tests/test_ibft.sh` the patch (against a stand-in `minimal-init`), the subnet arithmetic and `ibft-root-setup`; `tests/test_oci_ibft.sh` the recipe on a synthetic disk (kernel image with an embedded initramfs, USR-A with a library and modules), including the cases where it must fail. `scripts/boot-test-iscsi.sh` boots the image twice in QEMU/KVM with OVMF:

- iSCSI: no local disk. iPXE (built from a pinned source with a script embedded) logs in to a `tgt` target (a docker container with a pinned base image) that serves the image, and boots from it; it publishes the iBFT, as the shape's firmware does. The target is on the iBFT gateway's address, so the off-subnet route is not exercised (the unit test covers the arithmetic).
- VM: the same image as a virtio disk. The early init must not log in to anything: no `iBFT:` line.

Ignition runs on the `oraclecloud` platform against a fake metadata service (QEMU forwards 169.254.169.254 to `tests/boot/metadata-server.py`) and installs `tests/boot/ibft-check.sh`, which writes its results to the kernel log and reboots once. The test passes when both boots show: login prompt; (iSCSI) `iscsid` active, a `LOGGED_IN` session with the iBFT initiator name, the 6000 s timeout, `00-ibft.network` applied, the address kept and root I/O working over a `systemd-networkd` restart, a clean reboot on the iSCSI root; no I/O error in the kernel log. The logs stay in the work directory.

## Use the image on Oracle Cloud

Upload the `.qcow2` to Object Storage, import it, and allow each shape:

```sh
oci compute image import from-object-uri --uri <object URL> --source-image-type QCOW2 \
  --launch-mode PARAVIRTUALIZED --display-name flatcar-<channel>-<version>-amd64
oci compute image-shape-compatibility-entry add --image-id <image OCID> --shape-name <shape>
```

Use the Spare Cores release's checksum and signature as described in the README.
