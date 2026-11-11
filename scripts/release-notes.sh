#!/usr/bin/env bash
# Print release notes (markdown) for a manifest.json.
#
# usage: release-notes.sh MANIFEST
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# -eq 1 ]] || die "usage: release-notes.sh MANIFEST"
need jq

jq -r '
  "Flatcar \(.channel) \(.version): generic image with the OEM id set per vendor.\n",
  "| Artifact | Vendor | OEM id | Arch | Format | Size | sha256 |",
  "|---|---|---|---|---|---|---|",
  (.artifacts[] | "| `\(.name)` | \(.vendor) | `\(.oem_id)` | \(.arch) | \(.format) | \(.size) | `\(.sha256)` |"),
  "\nEvery file has a Sigstore bundle (`<file>.sigstore.json`). Verify with `scripts/verify.sh`; see the README.",
  "\nBoot on the vendor is not verified by this repository."' "$1"
