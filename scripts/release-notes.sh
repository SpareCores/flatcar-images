#!/usr/bin/env bash
# Print release notes (markdown) for a manifest.json.
#
# usage: release-notes.sh MANIFEST [ARTIFACT]
# With ARTIFACT, print only its table row (release-gce-arm64.sh notes uses it
# to rewrite the row of a release that already has notes).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# -ge 1 && $# -le 2 ]] || die "usage: release-notes.sh MANIFEST [ARTIFACT]"
need jq

if [[ $# -eq 2 ]]; then
  jq -er --arg n "$2" '.artifacts[] | select(.name == $n) | "| `\(.name)` | \(.vendor) | `\(.oem_id)` | \(.arch) | \(.format) | \(.size) | `\(.sha256)` |"' "$1" ||
    die "no artifact $2 in $1"
  exit 0
fi

jq -r '
  "Flatcar \(.channel) \(.version): the official image per vendor with the OEM id set. oraclecloud-iscsi is made from the official oraclecloud image and carries one extra initrd for iSCSI boot (docs/oraclecloud-iscsi.md); it is booted in QEMU before release.\n",
  "| Artifact | Vendor | OEM id | Arch | Format | Size | sha256 |",
  "|---|---|---|---|---|---|---|",
  (.artifacts[] | "| `\(.name)` | \(.vendor) | `\(.oem_id)` | \(.arch) | \(.format) | \(.size) | `\(.sha256)` |"),
  "\nEvery file has a Sigstore bundle (`<file>.sigstore.json`). Verify with `scripts/verify.sh`; see the README.",
  "\nBoot on the vendor is not verified by this repository."' "$1"
