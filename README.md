# flatcar-images

[Flatcar Container Linux](https://www.flatcar.org/) images for the cloud vendors that have no official Flatcar image, built from Flatcar's own release files and published as signed GitHub releases.

A generic Flatcar image has no OEM id: on a vendor without an official image it runs Ignition as `qemu` (fw_cfg) and boots unconfigured. The only thing that differs between an official OEM image and a generic one is one file on the OEM partition, `grub.cfg` with `set oem_id="<id>"`. This repository downloads the official generic image, verifies it, writes that one file, and repackages the disk in the format each vendor imports. Nothing else in the image changes (the build checks that everything outside the OEM partition is byte-identical to Flatcar's image).

It is part of how [SpareCores/scarpenter](https://github.com/SpareCores/scarpenter) finds a boot image per vendor, and anyone else can use the releases the same way. It holds no cloud credentials (the GCP publishing uses keyless federation) and never boots an image on a vendor.

## The image ladder

Where a node's image comes from, in order of preference:

1. A public Flatcar image the vendor offers. Use it; this repository is not needed.
2. The vendor lets anyone publish public images: Spare Cores publishes them there (GCP arm64 is implemented, see below; Alibaba community images later).
3. Images are created in your own account from the artifacts of this repository, with your infrastructure as code. This is the rung for UpCloud, Vultr and Alibaba today.
4. The controller imports the image itself: not used.

When Flatcar ships an official image for a platform, this repository stops building it from the release that carries it and points to the official file. Versions already built stay available.

## What is built

| Vendor | OEM id | Arch | Artifacts per release | Channels |
|---|---|---|---|---|
| UpCloud | `upcloud` | amd64 | `flatcar-upcloud-<channel>-<version>-amd64.img.gz` (raw, gzip) | stable, beta, alpha. **Not LTS**: the LTS release ships an Ignition without the `upcloud` platform (needs 2.23 or later). |
| Vultr | `vultr` | amd64 | `flatcar-vultr-<channel>-<version>-amd64.img.gz` (raw, gzip) | all |
| Alibaba Cloud | `aliyun` | amd64, arm64 | `flatcar-aliyun-<channel>-<version>-<arch>.qcow2` (compressed) and `.img.gz` (raw, gzip) | all |
| Google Cloud | `gce` | arm64 | `flatcar-gce-<channel>-<version>-arm64.tar.gz` (one sparse `disk.raw`, whole GiB, `oldgnu` tar) | all |

Stable and LTS are built automatically when Flatcar releases them (a daily check, see below). Beta and alpha are built on request: run the `build` workflow by hand, or set `"track": true` in `config/channels.json`.

One release per Flatcar version, tag `<channel>-<version>` (for example `stable-4757.2.3`). A version is never rebuilt over an existing release, so an image someone created from an artifact always matches its checksum; a fix is a new release with a suffix (`stable-4757.2.3-r2`). Releases are not deleted.

Raw images (about 8.5 GB for amd64 stable 4757.2.3) do not fit a release asset (2 GiB), so only compressed artifacts are released. `make build ... ALL_FORMATS=1` also builds the raw Vultr image for hosting elsewhere.

## Use the releases

Each release has `manifest.json`, which maps the pinned Flatcar version to its artifacts:

```json
{
  "schema": 1, "repository": "SpareCores/flatcar-images",
  "tag": "stable-4757.2.3", "channel": "stable", "version": "4757.2.3",
  "artifacts": [{
    "name": "flatcar-vultr-stable-4757.2.3-amd64.img.gz",
    "vendor": "vultr", "oem_id": "vultr", "arch": "amd64",
    "format": "raw-gzip", "size": 0, "sha256": "...",
    "url": "https://github.com/SpareCores/flatcar-images/releases/download/stable-4757.2.3/flatcar-vultr-stable-4757.2.3-amd64.img.gz",
    "source_image": { "url": "...", "sha512": "...", "sha256": "...", "signed_by": "F88CFEDE..." }
  }]
}
```

`source_image` is the official `flatcar_production_image.bin.bz2` the artifact was made from, with the SHA512 Flatcar signed. The artifact URL is stable: `https://github.com/SpareCores/flatcar-images/releases/download/<channel>-<version>/<artifact>`.

Name the image you create in your account so that a pinned version maps to exactly one image (the conventions SCarpenter reads): UpCloud template labels `scarpenter-image=flatcar`, `flatcar-channel`, `flatcar-version`, `flatcar-arch`, `flatcar-tier` and title `flatcar-<channel>-<version>-amd64-<tier>`; Vultr snapshot description `flatcar-<channel>-<version>-<arch>`; Alibaba image name `Flatcar-<channel>-<version>-<arch>` with tags `flatcar-channel`, `flatcar-version`, `arch`, `built-by`. See the SCarpenter documentation for the full contract.

## Verify a release

Every file, `SHA256SUMS` and `manifest.json` have a keyless [Sigstore](https://www.sigstore.dev/) bundle (`<file>.sigstore.json`), signed by this repository's `build` workflow through GitHub's OIDC identity. No key to fetch; you need [cosign](https://github.com/sigstore/cosign) v3 or later (the bundles are in the Sigstore bundle format that cosign v3 writes; cosign 2.5 and 2.6 read them only with `--new-bundle-format`). The certificate identity is the `build` workflow on `main` and the issuer is GitHub Actions; `build.yml` refuses to release from any other ref. Download the files you want, `SHA256SUMS` and the `.sigstore.json` bundles into one directory, then:

```sh
scripts/verify.sh ./download-dir
```

or by hand:

```sh
cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/SpareCores/flatcar-images/\.github/workflows/build\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
```

The same checksums also have a GitHub build provenance attestation: `gh attestation verify <file> --repo SpareCores/flatcar-images`.

The build itself verifies Flatcar's `.DIGESTS.asc` against Flatcar's image signing key, pinned by fingerprint (`F88CFEDEFF29A5B4D9523864E25D9AED0593B34A`, key in `keys/`), and takes the SHA512 from the signed text.

## Import per vendor

None of this is automated here; it is what your infrastructure as code does once per pinned version. All of it is **unverified live**: no image from this repository has been booted on a vendor yet.

- **UpCloud**: create a storage from the artifact with `http_import` (UpCloud accepts raw, gzip and xz; not qcow2 or bz2), then templatize. Console and `direct_upload` work too. Whether UpCloud accepts the content type GitHub serves release assets with is open.
- **Vultr**: `POST /v2/snapshots/create-from-url` with the artifact URL, description `flatcar-<channel>-<version>-<arch>`. Whether Vultr accepts a gzip file or needs a raw one (which needs hosting outside GitHub releases) is open.
- **Alibaba Cloud**: upload the artifact to OSS in one region and `ImportImage` (RAW, QCOW2 and VHD are accepted, bz2 is not; the plan prefers the compressed qcow2, gunzip the `.img.gz` for RAW), then `CopyImage` to other regions. Which format `CopyImage` accepts is open. No VHD artifact is built.
- **Google Cloud (arm64)**: see below.

## Status

| Vendor | Build | Boot on the vendor |
|---|---|---|
| UpCloud amd64 | implemented, tested on synthetic images | not yet verified live |
| Vultr amd64 | implemented, tested on synthetic images | not yet verified live; import format open |
| Alibaba amd64, arm64 | implemented, tested on synthetic images | not yet verified live; import format open |
| GCE arm64 | implemented (`tar.gz` with `disk.raw`) and published by `publish-gcp.yml`, tested on synthetic images and a stubbed `gcloud` | not yet verified live; nothing has been published yet |

"Boot not yet verified live" means the OEM id patch is tested (the file is written, the rest of the disk is unchanged, a real Flatcar signature verifies) and a patched stable 4757.2.3 amd64 image booted locally in QEMU (BIOS) with `flatcar.oem.id=upcloud` on the kernel command line, but nobody has run Ignition on the vendor's metadata service with these images. Each vendor's boot check belongs to SCarpenter's vendor test lanes.

### GCP arm64 publishing

Flatcar publishes no GCE arm64 image. This repository builds the `tar.gz` and, when its owner has set the repository variables, `publish-gcp.yml` turns each release into a public image in a GCP project: workflow after `build` succeeds (or by hand for an existing release), keyless login through workload identity federation (`id-token: write`, `contents: read`, no secret, no key), the release files verified with `scripts/verify.sh`, then `scripts/publish-gcp.sh`:

1. Upload the tarball to the bucket (`import/<image>.tar.gz`).
2. `gcloud compute images create flatcar-<channel>-<major>-<minor>-<patch>-arm64` (`-rN` for a release revision) with `--architecture=ARM64`, guest OS features `UEFI_COMPATIBLE`, `VIRTIO_SCSI_MULTIQUEUE`, `GVNIC`, family `flatcar-<channel>-arm64`, labels `flatcar-channel`, `flatcar-version` (dots as dashes) and `built-by=spare-cores`, in the multi-region storage location.
3. `add-iam-policy-binding` `roles/compute.imageUser` for `allAuthenticatedUsers`.
4. Delete the uploaded object (the image keeps its own copy; a bucket lifecycle rule is the backstop).

It is idempotent: an image that exists is not created again (its sharing is still ensured), a `FAILED` one from a half-run is deleted and recreated, a `PENDING` one is waited for. Runs are serialised by a concurrency group, and a rate-limit error (one image creation per 10 minutes) is retried with backoff. While the variables are unset the workflow ends with a notice and succeeds. `scripts/publish-gcp.sh --dry-run CHANNEL VERSION` prints the commands and runs nothing; the tests run it against a stub `gcloud`.

Owner setup (project, bucket, least-privilege service account, workload identity restricted to this repository, `main` and the workflow file, the five variables): [docs/gcp-setup.md](docs/gcp-setup.md), with `scripts/setup-gcp.sh` to print or apply it.

Open (**unverified**): whether `gce` is the right OEM id for Ignition's `gcp` platform on arm64, the serial console arguments, and that the image boots at all. There is no arm64 `oem-gce` sysext, so no guest agent, no OS Login and no `/dev/disk/by-id/google-*` udev rules.

## How it works

```
scripts/fetch.sh         download image + DIGESTS.asc, verify signature and SHA512
scripts/patch-oem.sh     write /grub.cfg into the OEM partition (btrfs, ext4 or FAT)
scripts/package.sh       raw gzip, qcow2, GCE tar; meta.json per artifact
scripts/build.sh         the three above for one (channel, version, arch, vendor)
scripts/manifest.sh      manifest.json and SHA256SUMS
scripts/matrix.sh        build matrix of a channel; UpCloud skips LTS
scripts/track.sh         tracked releases without a GitHub release
scripts/verify.sh        what a consumer runs
scripts/publish-gcp.sh   create and share the GCE arm64 image from a release
scripts/setup-gcp.sh     print or apply the owner's one-time GCP setup
config/platforms.json    per vendor: OEM id, architectures, formats, skipped channels
config/channels.json     channels built automatically
```

Patching needs no root. The OEM partition (GPT name `OEM`, partition 6) is cut out of the disk with `dd` using offsets from `sfdisk --json` and copied back with `dd conv=notrunc`. In current Flatcar it is btrfs, for which no user-space writer exists: its files are extracted with `btrfs restore` and the filesystem is recreated with `mkfs.btrfs --rootdir` at the same size, with the same label, UUID, node size, mixed block groups and block group tree, under `fakeroot` so every file is owned by root. ext4 (`debugfs`) and FAT (mtools) are handled too. Loop mounts and guestfish would need root or a FUSE/libguestfs appliance; this runs identically on GitHub-hosted runners and a laptop. The script digests everything outside the partition before and after, checks the filesystem (`btrfs check`, `e2fsck`), checks that `grub.cfg` is root-owned with mode 0644, and reads it back.

GitHub workflows: `pr.yml` (lint and tests), `track-releases.yml` (daily: reads each tracked channel's `version.txt` from the Flatcar release server, dispatches `build.yml` for versions without a release), `build.yml` (build matrix, then a `sign` job with `id-token: write`, then a `release` job, the only one with `contents: write`; a failed build opens one issue per version, and later failures of the same version, such as the next day's retry by `track-releases.yml`, comment on it). `publish-gcp.yml` (after `build` succeeds, or by hand; the only workflow that talks to a cloud, with `id-token: write` and `contents: read`, configured by repository variables and skipped while they are unset). Actions are pinned by commit SHA, no secrets are used.

## Develop

Needs `bash`, `jq`, `curl`, `gpg`, `bzip2`, `gzip`, GNU `tar`, `sfdisk` and `sgdisk` (`gdisk`), `btrfs-progs` (6.1 or later, for the block group tree), `fakeroot`, `e2fsprogs`, `qemu-img`, and `mtools` and `dosfstools` for the FAT tests. `shellcheck` and `actionlint` for `make lint`.

```sh
make lint
make test      # no network, synthetic disks, fake release server with a throwaway key
make build CHANNEL=stable VERSION=4757.2.3 ARCH=amd64 VENDOR=upcloud   # downloads about 0.6 GB
```

## Upstream

Flatcar's own images are the better long-term answer. The plan is to propose `upcloud`, `vultr` and `aliyun` image types and a GCE arm64 image to Flatcar once the vendor boots are verified; this repository then stops building them.

## Licence

MPL-2.0 for the scripts (see `LICENSE`). The images are Flatcar's and stay under their licences.
