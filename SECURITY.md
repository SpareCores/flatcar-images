# Security policy

## Reporting

Please report vulnerabilities privately through GitHub's private vulnerability reporting for this repository (Security tab, "Report a vulnerability"). Do not open a public issue. We aim to acknowledge within a few working days.

## Scope

In scope: the build scripts and workflows, the signing and release process, and anything that would let an artifact differ from what the documented build produces (a wrong or unverified source image, a change outside the OEM partition, a bad signature).

Out of scope: vulnerabilities in Flatcar Container Linux itself (report them to the [Flatcar project](https://www.flatcar.org/security)) and in the cloud vendors' platforms.

## Verifying what you download

Releases are signed keyless with Sigstore from this repository's `build` workflow, and the source image is verified against Flatcar's pinned image signing key. See "Verify a release" in the [README](README.md). The images contain Flatcar's software unchanged except for the OEM id; keep nodes updated by pinning a current Flatcar version.
