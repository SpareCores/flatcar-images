#!/usr/bin/env bash
# Run in the SDK container by build-gce-arm64.sh before build_packages.
#
# Flatcar's binary packages for <version> (the board's PORTAGE_BINHOST) are
# built against the dependency metadata of the release's own SDK. In the SDK
# container of a patch release (4757.0.0 for 4757.2.3) portage sees that
# metadata as changed for most packages and, with its default
# --binpkg-changed-deps=y, throws the binary packages away and compiles
# them (140 of 289 packages, including openssl, systemd and rsync, whose
# distfile mirrors can fail). The tree is the release's, so the binary
# packages are right: --binpkg-changed-deps=n takes them. Packages the fork
# revision-bumps (the kernel and its modules) have no binary package and are
# still compiled.
set -euo pipefail
conf=/build/arm64-usr/etc/portage/make.conf.user
sudo touch "$conf"
if ! grep -q 'binpkg-changed-deps' "$conf"; then
  # shellcheck disable=SC2016 # the variable is expanded by portage
  echo 'EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS} --binpkg-changed-deps=n"' | sudo tee -a "$conf" >/dev/null
fi
sudo cat "$conf"
