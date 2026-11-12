#!/usr/bin/env bash
# What a consumer runs: check downloaded release files against SHA256SUMS and
# their keyless cosign bundles.
#
# usage: verify.sh DIR
#
# DIR holds SHA256SUMS and the downloaded files, each with its
# <file>.sigstore.json. Only files that are present are checked, but
# SHA256SUMS itself must verify.
# Needs cosign v3 or later (the bundles are in the new Sigstore bundle
# format; cosign 2.5 and 2.6 need --new-bundle-format). Set
# VERIFY_SKIP_SIGNATURES=1 to check the sums only.
#
# Env: CERT_IDENTITY_REGEXP (default: the build or build-gce-arm64 workflow of
# this repository on main), CERT_OIDC_ISSUER (default: GitHub Actions).
# build-gce-arm64 signs the GCE arm64 artifact, manifest.json and SHA256SUMS of
# a release it adds that artifact to; build signs everything else.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -eq 1 ]] || die "usage: verify.sh DIR"
dir=$1
identity=${CERT_IDENTITY_REGEXP:-^https://github\.com/SpareCores/flatcar-images/\.github/workflows/(build|build-gce-arm64)\.yml@refs/heads/main$}
issuer=${CERT_OIDC_ISSUER:-https://token.actions.githubusercontent.com}
need sha256sum
[[ -f $dir/SHA256SUMS ]] || die "no SHA256SUMS in $dir"

verify_sig() {
  cosign verify-blob --bundle "$1.sigstore.json" \
    --certificate-identity-regexp "$identity" \
    --certificate-oidc-issuer "$issuer" "$1" >/dev/null
}

if [[ ${VERIFY_SKIP_SIGNATURES:-0} != 1 ]]; then
  need cosign
  verify_sig "$dir/SHA256SUMS" || die "signature of SHA256SUMS does not verify"
fi

(cd "$dir" && sha256sum --check --ignore-missing --quiet SHA256SUMS) || die "checksum mismatch"

checked=0
while read -r _ name; do
  [[ -f $dir/$name ]] || continue
  if [[ ${VERIFY_SKIP_SIGNATURES:-0} != 1 ]]; then
    verify_sig "$dir/$name" || die "signature of $name does not verify"
  fi
  checked=$((checked + 1))
  log "ok: $name"
done <"$dir/SHA256SUMS"
[[ $checked -gt 0 ]] || die "none of the files in SHA256SUMS is present in $dir"
