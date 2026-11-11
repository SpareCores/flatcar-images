#!/usr/bin/env bash
# Shared helpers. Source this file; it sets no shell options.
# shellcheck shell=bash disable=SC2034

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLATFORMS_JSON=${PLATFORMS_JSON:-$REPO_ROOT/config/platforms.json}
CHANNELS_JSON=${CHANNELS_JSON:-$REPO_ROOT/config/channels.json}
REPOSITORY=${GITHUB_REPOSITORY:-SpareCores/flatcar-images}
# GitHub release assets are limited to 2 GiB.
MAX_ASSET_BYTES=2147483647

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

need() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
  done
}

valid_channel() { [[ $1 =~ ^(stable|lts|beta|alpha)$ ]] || die "invalid channel: $1"; }
valid_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version: $1"; }
valid_arch() { [[ $1 =~ ^(amd64|arm64)$ ]] || die "invalid arch: $1"; }
valid_platform() {
  [[ $1 =~ ^[a-z0-9]+$ ]] || die "invalid platform: $1"
  jq -e --arg p "$1" '.platforms[$p]' "$PLATFORMS_JSON" >/dev/null || die "unknown platform: $1"
}

# platform_field PLATFORM JQ_EXPR
platform_field() { jq -r --arg p "$1" ".platforms[\$p] | $2" "$PLATFORMS_JSON"; }

# release_url CHANNEL ARCH VERSION: base URL of a release directory.
# FLATCAR_RELEASE_BASE (tests only) replaces the release servers with
# <base>/<channel>/<arch>-usr/<version>.
release_url() {
  local channel=$1 arch=$2 version=$3
  if [[ -n ${FLATCAR_RELEASE_BASE:-} ]]; then
    printf '%s/%s/%s-usr/%s' "${FLATCAR_RELEASE_BASE%/}" "$channel" "$arch" "$version"
  else
    printf 'https://%s.release.flatcar-linux.net/%s-usr/%s' "$channel" "$arch" "$version"
  fi
}

# artifact_name PLATFORM CHANNEL VERSION ARCH EXT
artifact_name() { printf 'flatcar-%s-%s-%s-%s.%s' "$1" "$2" "$3" "$4" "$5"; }

# release_tag CHANNEL VERSION [REVISION]
release_tag() { printf '%s-%s%s' "$1" "$2" "${3:+-$3}"; }

download() {
  curl --fail --silent --show-error --location \
    --retry 5 --retry-delay 3 --retry-all-errors --output "$2" "$1"
}
