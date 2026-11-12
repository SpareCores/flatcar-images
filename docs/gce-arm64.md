# GCE arm64: the image built from a kernel fork

The `gce` arm64 artifact (`flatcar-gce-<channel>-<version>[-<revision>]-arm64.tar.gz`) is not the generic Flatcar image with an OEM id written into it, like the other artifacts of this repository. It is built from source by the `build-gce-arm64` workflow, from a fork of [flatcar/scripts](https://github.com/flatcar/scripts).

## Why a kernel fork

Every GCE arm64 machine type (T2A, C4A) has a gVNIC network device and nothing else. Flatcar's arm64 kernel has no gVNIC driver (`# CONFIG_GVE is not set`), so on GCE the initrd has no network, Ignition cannot fetch the user data and the VM ends in the emergency target and reboots in a loop. The generic arm64 image with `flatcar.oem.id=gce` boots no further than that; a boot test of it on T2A and C4A showed this. Flatcar also builds no arm64 `oem-gce` OEM sysext (the guest scripts and the udev rules for `/dev/disk/by-id/google-*`), and its GCE `grub.cfg` has no arm64 console. None of this can be fixed by changing a file on the OEM partition: the kernel and the initrd have to change.

## The fork

[SpareCores/flatcar-scripts](https://github.com/SpareCores/flatcar-scripts), branch `gce-arm64`: four commits on top of the upstream release tag (`stable-4757.2.3` at the time of writing):

| Commit | Change |
|---|---|
| `sys-kernel/coreos-modules` | `CONFIG_GVE=m` moved from the amd64 defconfig to `commonconfig`, so arm64 builds the gVNIC driver as a module |
| `sys-kernel/coreos-kernel` | `coreos-modules` and `coreos-kernel` revision-bumped to `-r1` (portage reuses a binary package whenever the version matches, so without it the unchanged-version kernel would come from Flatcar's cache without the driver); `google-guest-configs` (the dracut module with the GCE disk naming rules) is installed in the initrd on arm64 too |
| `coreos-base/oem-gce` | `arm64` keyword for `oem-gce`, `google-guest-configs` and `google-compute-engine`, so the GCE OEM sysext is built for arm64; the GCE `grub.cfg` uses the PL011 console (`ttyAMA0`) on arm64 |
| changelog | entry for the above (for a later proposal to Flatcar, flatcar/Flatcar#2000) |

`bootengine` needs no change: its dracut call installs every network driver of the kernel, so `gve.ko` lands in the initrd as soon as the module exists.

## Rebuild

Dispatch the workflow from `main` (it refuses any other ref):

```sh
gh workflow run build-gce-arm64.yml --ref main -f channel=stable -f version=4757.2.3
# optional: -f fork_ref=gce-arm64 -f fork_repository=SpareCores/flatcar-scripts -f revision=r2
```

It is not part of `track-releases.yml` and does not trigger `publish-gcp.yml`: after it succeeds, dispatch `publish-gcp.yml` for the version by hand (with the same `revision`).

What it does (`scripts/build-gce-arm64.sh`):

1. The `plan` job validates the inputs on a GitHub-hosted runner. The fork must be a repository of the SpareCores organisation: the build runs the fork's code as root on the shared runner.
2. The `build` job (`runs-on: [self-hosted, workhorse]`, 6 hours) checks out the fork with all tags into a per-run directory and checks that the fork ref is based on the upstream tag `<channel>-<version>` (and is not that tag itself), and that `sdk_container/.repo/manifests/version.txt` names the version.
3. In Flatcar's SDK container (`ghcr.io/flatcar/flatcar-sdk-all`, the version from `FLATCAR_SDK_VERSION` in that file, as Flatcar's own CI picks it; an amd64 host, privileged Docker, about 100 GB free) it runs, niced:
   ```
   ./run_sdk_container -U ./build_packages --board=arm64-usr
   ./run_sdk_container -U ./build_image --board=arm64-usr --group=<channel> prod oem_sysext
   ./run_sdk_container -U ./image_to_vm.sh --board=arm64-usr --format=gce
   ```
   arm64 is cross-compiled. The packages come from Flatcar's binary cache for that release; the changed ones are built: the kernel cross-compile takes 30 to 60 minutes, the whole run one to two hours. `-U` makes the SDK use `version.txt` as it is: the fork's `HEAD` is not the tag, so `git describe` would give `stable-4757.2.3-4-g<hash>` and the SDK would point the binary cache at a build that does not exist.
4. `scripts/verify-gce-arm64.sh` (in the SDK container, which has `btrfs-progs` and `sfdisk`) checks:
   - `CONFIG_GVE=m` in the kernel config `build_image` wrote for the image;
   - `gve.ko` in the contents list of the full initrd (`usr/lib/flatcar/bootengine.img`, the squashfs on the USR partition that Ignition runs from). To look yourself: `mount -o loop,ro` that file (or `unsquashfs` it) and list `usr/lib/modules/*/kernel/drivers/net/ethernet/google/gve/`;
   - the GCE udev rules (`65-gce-disk-naming.rules`) and `google_nvme_id` in the `oem-gce` sysext's contents list;
   - on the built disk: the OEM partition (read in user space with `btrfs restore`) has a `grub.cfg` with `oem_id="gce"` and `ttyAMA0`, and its `sysext/oem-gce-*.raw` is active and byte for byte the sysext that was checked.
5. `scripts/package.sh` repackages the `disk.raw` in this repository's format (one sparse `disk.raw`, a whole number of GiB, `oldgnu` tar), with `source: {repository, ref, commit}` of the fork in the manifest entry (plus the upstream tag and the SDK version).
6. The `sign` job signs the tarball, `manifest.json` and `SHA256SUMS` keylessly (identity: this workflow on `main`) and attests the tarball's provenance. The `release` job (the only one with `contents: write`) uploads them to the release `<channel>-<version>[-<revision>]` with `--clobber`: an existing asset of the same name, the earlier OEM-patched GCE artifact, is replaced and the release notes say so. `manifest.json` keeps the other artifacts of the release as they were. A missing release is created.
7. An `always()` step removes the SDK container (`docker rm --force --volumes`), loop devices that still point at images of the run, and the per-run directory (`__build__`, the SDK cache). The SDK image stays cached; nothing else on the host is touched.

The kernel config, the initrd and sysext contents, the package list and the verification log are kept for 30 days as the `gce-arm64-evidence` artifact of the run.

Consumers verify the release as before (`scripts/verify.sh`, which accepts the signatures of both `build` and `build-gce-arm64`).

## Rebase the fork onto a new Flatcar release

The fork is tied to one release tag; for a new version it has to be carried over:

```sh
git clone https://github.com/SpareCores/flatcar-scripts && cd flatcar-scripts
git fetch https://github.com/flatcar/scripts --tags
git switch -c gce-arm64-new stable-4800.0.0          # the new upstream tag
git cherry-pick stable-4757.2.3..origin/gce-arm64    # the four commits
```

Then go through what the commits touch, because upstream moves:

- the kernel: the config files are named by kernel series (`commonconfig-6.12`, `amd64_defconfig-6.12`) and the ebuilds by kernel version. After a kernel update the `-r1` revision bump moves to the new `coreos-modules-<ver>.ebuild` and `coreos-kernel-<ver>.ebuild` (`git mv` them to `-<ver>-r1.ebuild`, or `-r2` when upstream already uses `-r1`); `CONFIG_GVE=m` belongs in the `commonconfig` of the new series. Upstream may already have it, in which case the commit shrinks to the rest;
- the keywords and the `coreos-kernel` dependency edit apply to whatever version of `oem-gce`, `google-guest-configs` and `google-compute-engine` the new tag has;
- the GCE `grub.cfg` (`build_library/oem/gce/grub.cfg`).

Push the branch (replace `gce-arm64` or pass `fork_ref`), dispatch the workflow, and read the `gce-arm64-evidence` artifact: the verification fails the run if the driver or the OEM files are missing. The kernel build also dies by itself when `make olddefconfig` drops a config option that was set (a missing dependency of `GVE`). Whether the image really boots is a separate check on GCE (T2A and C4A); the build cannot tell.

When Flatcar ships `gve` for arm64 and the GCE OEM sysext itself, drop the fork: remove the `built_by` mark of `gce` in `config/platforms.json` so `build.yml` builds it again, or point to the official image.

## Nodes must not auto-update

A node running this image that updates through Flatcar's update service gets the stock arm64 image, without `gve`, and loses its network at the next boot. Disable updates on such nodes, for example with Ignition:

```yaml
storage:
  files:
    - path: /etc/flatcar/update.conf
      overwrite: true
      contents:
        inline: |
          SERVER=disabled
```

(and, if you want, mask `update-engine.service` and `locksmithd.service`). Update by creating nodes from a newer image of this repository instead.

## The runner

`build-gce-arm64.yml` is the only workflow that uses `runs-on: [self-hosted, workhorse]`. The runner is shared by the organisation, runs jobs as root and needs Docker. That is why the workflow takes `workflow_dispatch` only (never a pull request or a push, which could run code from a fork of this repository), refuses any ref but `main`, accepts only a SpareCores repository as the fork, serialises runs in the `build-gce-arm64` concurrency group and cleans up after itself. Keep it that way when changing the workflow; `tests/test_config.sh` checks the triggers, the runner use, the ref guard and the action pinning.
