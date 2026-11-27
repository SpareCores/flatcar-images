# Oracle Cloud bare metal: Flatcar on an iSCSI boot volume

The `oraclecloud-iscsi` image is the official Flatcar `oraclecloud` image with one extra initrd and one GRUB menu entry on the OEM partition. It boots on Oracle Cloud bare metal shapes (for example `BM.Standard.E2.64` on amd64, `BM.Standard.A1.160` on arm64) and, unchanged, on VM shapes. amd64 and arm64.

Status: booted in QEMU via iSCSI/iBFT on both architectures (the boot test below runs in CI; arm64 under software emulation). OCI bare metal live boot pending; arm64 Ampere bare metal is not tested live at all (its firmware is known to publish an iBFT, see [arm64](#arm64)). Upstream issue: <https://github.com/flatcar/Flatcar/issues/2516>.

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

`scripts/oci-ibft.sh` builds it from the image itself, without root and without mounting: `vmlinuz-a` is read from the ESP with mtools (on arm64 it is a plain `Image`; on amd64 a bzImage whose payload is unpacked first), `/usr` from USR-A with `btrfs restore`.

- `/ibft-init`: the embedded initramfs's `minimal-init` with `patches/minimal-init-ibft.patch` applied, started by `rdinit=/ibft-init`. Its first line runs the embedded `/init` instead unless `uname -r` is the kernel version baked in at build time, so a `flatcar-ibft.cpio` left on the OEM partition by an older release (after two updates the slot A kernel is newer than the initrd) never takes over. The build fails if the patch does not apply: a new release changed `minimal-init` and the patch needs a look.
- `/usr/lib/ibft/`: `iscsistart` and the shared libraries it needs that the embedded initramfs lacks (found by walking the ELF `NEEDED` entries; today `libopeniscsiusr` and `libkmod`), run with `LD_LIBRARY_PATH` set. No file of the embedded initramfs is replaced, except the `modules.*` indexes (below).
- `/usr/lib/ibft/ibft-acpi-parse`: reads the iBFT as the raw ACPI table, for kernels without `iscsi_ibft` (arm64, see below).
- The modules `iscsi_ibft` (amd64 only), `bnxt_en` (E2 shapes), `mlx5_core` (newer shapes) and `virtio_net` (QEMU, for the boot test), with the dependencies that the embedded initramfs lacks, resolved from USR-A's `modules.dep`. The list is in the script and is written into the initrd as `/etc/ibft-modules`. `modules.*` are regenerated with `depmod` over the embedded and the added modules; the build fails if a module of the embedded initramfs differs from USR-A's copy.
- `/etc/iscsi/iscsid.conf`: USR-A's, with `node.session.timeo.replacement_timeout = 6000`: during a connection drop I/O queues for up to 6000 s instead of failing after 120 s.
- The files of `overlay/`: `ibft-root-setup` and its unit, used in the dracut stage.

The archive is newc, root-owned, sorted and with fixed mtimes: the same image gives the same bytes.

## What happens at boot

Without an iBFT (a VM, or any machine without iSCSI boot) `iscsi_ibft_login` returns right after it finds neither `/sys/firmware/ibft` nor the ACPI table, and the boot is the stock one apart from the unused initrd.

With an iBFT, the early init (it logs `iBFT: ...` lines to the kernel log, so they show on every console and in `dmesg`):

1. loads `iscsi_tcp` and the NIC drivers, waits up to 30 s for the NIC with the iBFT's MAC address (the name is not predictable), brings it up with `iscsistart -N` (arm64: `ip addr add` from the parsed table, see below), adds a host route to the target through the iBFT gateway when the target is outside the NIC's subnet (it usually is: `169.254.0.2`);
2. logs in with `iscsistart -b` (arm64: `iscsistart` with explicit parameters), up to three times, waiting up to 10 s each for the disk (a NIC can be slow to bring its link up), and goes on with the stock steps (dm-verity on USR-A, mount, switch to the dracut stage);
3. right before the switch, prepares the dracut stage in `/realinit`:
   - `/etc/cmdline.d/90-ibft.conf` with `rd.iscsi.firmware=1 rd.neednet=1 netroot=iscsi:` (arm64 adds `rd.iscsi.initiator=<the iBFT's initiator name>`). dracut's `getarg` reads `/etc/cmdline.d` as well as `/proc/cmdline`, so its iscsi module, the `rd.neednet` network wait and the root session handling work as if the arguments were on the kernel command line. VMs never get the file.
   - `network-cleanup.service` masked. Its `ConditionKernelCommandLine=!netroot` reads only `/proc/cmdline`, which has no `netroot`, so unmasked it would flush the NIC's address at switch-root and the root disk with it.
   - `/etc/systemd/network/00-ibft.network` for the iBFT NIC (match by MAC, DHCP, `KeepConfiguration=yes`, `IgnoreCarrierLoss=yes`, the route to the target when it is off-subnet). The initrd's `yy-netroot.network` matches `KernelCommandLine=netroot` on `/proc/cmdline` only, so this file does its job in the initrd.
   - `ibft-root-setup.service`, which runs in the dracut stage after Ignition, before switch-root.

`ibft-root-setup` prepares the real root, in `/sysroot/etc`:

- `iscsi/initiatorname.iscsi` with the iBFT's initiator name (the target accepts only that one; `iscsi-init.service` would generate another);
- `iscsi/iscsid.conf` with the 6000 s timeout (replacing Flatcar's default copy);
- `systemd/network/00-ibft.network`, so that the running system keeps the NIC's address when `systemd-networkd` restarts or the lease is lost (the generic `zz-default.network` would drop it);
- `iscsid.service` and `iscsid.socket` enabled, so the root session is recovered after a drop. `iscsi.service` is not enabled: stopping it at shutdown would log the root session out too early.

It keeps files that exist (an Ignition config, a second boot), except Flatcar's default `iscsid.conf`. The dracut stage reads the initiator name from `/sys/firmware/ibft`, which is there because `iscsi_ibft` stays loaded, or, without that module, from `/etc/ibft.env`; nothing else has to be handed over. The early init writes `/etc/ibft.env` on every machine with an iBFT (and `ibft-root-setup` hands it to the real root) with what it read: `IBFT_INITIATOR`, `IBFT_MAC`, `IBFT_IP`, `IBFT_PREFIX`, `IBFT_GATEWAY`, `IBFT_TARGET_IP`, `IBFT_TARGET_PORT`, `IBFT_TARGET_NAME`.

## arm64

Flatcar's arm64 kernel (6.12) has `CONFIG_ISCSI_IBFT` unset: there is no `iscsi_ibft` module and so no `/sys/firmware/ibft`, although `CONFIG_ACPI=y`, the kernel logs `ACPI: iBFT ...` and exposes the table as `/sys/firmware/acpi/tables/iBFT`. Everything that reads the iBFT through sysfs fails there: `iscsistart -b` and `-N`, and dracut's `iscsiadm -m fw`. The initrd works around it:

- `ibft-acpi-parse` reads the binary table (with `hexdump` and `awk` of the initrd's busybox; there is no `od`) following the iBFT specification: header, control structure with the offsets of the initiator, NIC and target structures, the target with the "firmware boot selected" flag (else the first valid one) and the NIC it names. Structures shorter than the specification's are ignored; a prefix length outside 1 to 32 is refused. It checks signature, length and checksum, takes IPv4 addresses only, and refuses names with characters other than those of an IQN, so the early init can read its output safely. It prints the initiator name, the NIC's MAC, address, prefix length and gateway, and the target's address, port and name. CHAP is not read (Oracle Cloud does not use it).
- The early init configures the NIC with `ip addr add` (and the route to an off-subnet target, as on amd64) and logs in with `iscsistart -i <initiator> -t <target IQN> -g 1 -a <target IP> -p <port>`. `-g`, the target portal group tag, is required but not in the iBFT. The init starts with 1; the `iscsistart` of Flatcar 4757 accepts a wrong tag (it logs `Portal group tag mismatch ... Updating` and carries on, checked in QEMU with `-g 2` against a target whose tag is 1), but if a version fails the login with `expected 1, received N`, the init retries with the `N` the target reported.
- The raw path ignores the NIC's VLAN and adds no default route; the DHCP configuration of `00-ibft.network` does that later, in the dracut stage.
- The dracut stage needs nothing but the initiator name. With `rd.iscsi.firmware=1` its `iscsiroot` calls `iscsiadm -m fw`, which fails without sysfs and only warns; it then finds the session that the early init created in `/sys/class/iscsi_session` and treats it as the root session, without logging in or out. `rd.iscsi.initiator=<name>` makes dracut use the iBFT's initiator name, which the missing `/sys/firmware/ibft` would otherwise have supplied.

On amd64 the init prefers `/sys/firmware/ibft` and the path is unchanged. If upstream Flatcar enabled `CONFIG_ISCSI_IBFT=m` for arm64 the fallback would be unnecessary (the init uses the module when it is there).

Status: booted in QEMU (`-M virt`, AAVMF, iPXE built for arm64, software emulation) from the iSCSI target and from a plain disk. Oracle's Ampere shapes are not tested live: their firmware does publish an iBFT (`ACPI: iBFT ... ORACLE` on `BM.Standard.A1.160`), but the init has not run there. The parser follows the specification and does not depend on iPXE's table layout; its test fixture is the table iPXE publishes in the QEMU boot test.

## Limits

- The initrd is loaded only when the `USR-A` slot boots. After an update Flatcar boots slot B, and the stock path cannot log in to iSCSI: a VM still boots, a bare metal node does not. Keep updates off on bare metal nodes (mask `update-engine` and `locksmithd`, as SCarpenter does) or replace nodes per Flatcar version.
- The OEM `grub.cfg` is read only with secure boot off, which is how the shapes boot today.
- Not built for LTS: its initramfs has no `minimal-init` yet.
- A stale initrd with the same kernel version but another module set would still replace the `modules.*` indexes; Flatcar changes the version string with every kernel build, so this is not expected.
- Only the NIC drivers above. Another bare metal family needs its driver in the list in `scripts/oci-ibft.sh`.
- Only the iBFT's first NIC and first target (`ethernet0`, `target0`), no CHAP, IPv4.
- arm64 bare metal (`BM.Standard.A1.160`) is only booted in QEMU; its NIC should be a Mellanox one (`mlx5_core`, in the list).
- A release whose `minimal-init` or modules differ fails the build until the patch or the recipe is adapted. When Flatcar ships iSCSI boot in its own images, this image is no longer built for the releases that carry it.

## Build and test

```sh
make build CHANNEL=stable VERSION=4757.2.3 ARCH=amd64 VENDOR=oraclecloud-iscsi
scripts/boot-test-iscsi.sh out/stable-4757.2.3/flatcar-oraclecloud-iscsi-stable-4757.2.3-amd64.qcow2
ARCH=arm64 scripts/boot-test-iscsi.sh out/stable-4757.2.3/flatcar-oraclecloud-iscsi-stable-4757.2.3-arm64.qcow2   # after make build ... ARCH=arm64
```

`config/platforms.json` names the source image (`flatcar_production_oraclecloud_image.img`, a qcow2 file; verified like the generic image, against the signed `DIGESTS.asc`), turns the overlay on (`ibft_overlay`) and holds the GRUB lines.

`make test` covers what needs no boot: `tests/test_ibft.sh` the patch (against a stand-in `minimal-init`), the subnet arithmetic, `ibft-root-setup` and `ibft-acpi-parse` (on the iPXE table in `tests/fixtures/ibft-ipxe.bin`, on edited copies of it, with the host's tools and with busybox only); `tests/test_oci_ibft.sh` the recipe on synthetic amd64 and arm64 disks (kernel image with an embedded initramfs, USR-A with a library and modules), including the cases where it must fail. `scripts/boot-test-iscsi.sh` boots the image twice in QEMU: amd64 with OVMF under KVM, arm64 (`ARCH=arm64`) with AAVMF under software emulation (TCG, no KVM; needs `qemu-system-aarch64`, `qemu-efi-aarch64` and, on a non-arm64 host, `gcc-aarch64-linux-gnu` for iPXE; BOOT_TIMEOUT defaults to 2400 s per mode):

- iSCSI: no local disk. iPXE (built from a pinned source for the architecture, with a script embedded) logs in to a `tgt` target (a docker container with a pinned base image) that serves the image, and boots from it; it publishes the iBFT, as the shape's firmware does. The target is on the iBFT gateway's address, so the off-subnet route is not exercised (the unit test covers the arithmetic).
- VM: the same image as a virtio disk. The early init must not log in to anything: no `iBFT:` line.

Ignition runs on the `oraclecloud` platform against a fake metadata service (QEMU forwards 169.254.169.254 to `tests/boot/metadata-server.py`) and installs `tests/boot/ibft-check.sh`, which writes its results to the kernel log and reboots once. The test passes when both boots show: login prompt; (iSCSI) `iscsid` active, (arm64) no `iscsi_ibft` module and the ACPI table present, a `LOGGED_IN` session with the iBFT initiator name, the 6000 s timeout, `00-ibft.network` applied, the address kept and root I/O working over a `systemd-networkd` restart, a clean reboot on the iSCSI root; no I/O error in the kernel log. The logs stay in the work directory.

## Use the image on Oracle Cloud

Upload the `.qcow2` to Object Storage, import it, and allow each shape:

```sh
oci compute image import from-object-uri --uri <object URL> --source-image-type QCOW2 \
  --launch-mode PARAVIRTUALIZED --display-name flatcar-<channel>-<version>-<arch>
oci compute image-shape-compatibility-entry add --image-id <image OCID> --shape-name <shape>
```

Use the Spare Cores release's checksum and signature as described in the README.
