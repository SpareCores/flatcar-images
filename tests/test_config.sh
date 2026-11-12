#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_tools jq
source "$SCRIPTS/lib.sh"

P=$ROOT/config/platforms.json
assert_ok "platforms.json parses" jq -e . "$P"
assert_ok "channels.json parses" jq -e . "$ROOT/config/channels.json"

bad=$(jq -r '.platforms | to_entries[] | select(
  (.value.oem_id | test("^[a-z0-9_-]+$") | not)
  or (.value.arches | length == 0)
  or (.value.formats | length == 0)
  or (any(.value.formats[]; (.ext | length == 0) or (.kind | length == 0) or (.publish | type != "boolean")))
  or (.value.skip_channels | type != "array")
  or (.value.grub_extra | type != "array")) | .key' "$P")
assert_eq "every platform has an OEM id, arches, formats" "" "$bad"

assert_eq "OEM ids" "aliyun gce upcloud vultr" "$(jq -r '[.platforms[].oem_id] | sort | join(" ")' "$P")"
assert_eq "platform names are the vendor ids" "aliyun gce upcloud vultr" "$(jq -r '.platforms | keys | join(" ")' "$P")"
assert_eq "key fingerprint is pinned" "F88CFEDEFF29A5B4D9523864E25D9AED0593B34A" "$(jq -r .signing_key.fingerprint "$P")"
assert_ok "key file is in the repository" test -s "$ROOT/$(jq -r .signing_key.file "$P")"

# Artifact names follow flatcar-<platform>-<channel>-<version>-<arch>.<ext>.
assert_eq "artifact name" "flatcar-upcloud-stable-4757.2.3-amd64.img.gz" "$(artifact_name upcloud stable 4757.2.3 amd64 img.gz)"
assert_eq "release tag" "stable-4757.2.3" "$(release_tag stable 4757.2.3)"
assert_eq "release tag with revision" "stable-4757.2.3-r2" "$(release_tag stable 4757.2.3 r2)"
bad=$(jq -r '.platforms | to_entries[] | .key as $p | .value.arches[] as $a | .value.formats[]
  | "flatcar-\($p)-stable-1.2.3-\($a).\(.ext)"' "$P" | grep -vE '^flatcar-[a-z0-9]+-(stable|lts|beta|alpha)-[0-9.]+-(amd64|arm64)\.[a-z0-9.]+$' || true)
assert_eq "every artifact name matches the convention" "" "$bad"

# Plan 22: UpCloud skips LTS, aliyun has both arches. gce (arm64) is built by
# build-gce-arm64.yml from a kernel fork, so it is not in the build.yml matrix.
assert_eq "stable matrix" \
  "aliyun/amd64 aliyun/arm64 upcloud/amd64 vultr/amd64" \
  "$("$SCRIPTS/matrix.sh" stable | jq -r '[.include[] | "\(.vendor)/\(.arch)"] | sort | join(" ")')"
assert_eq "lts matrix has no upcloud" \
  "aliyun/amd64 aliyun/arm64 vultr/amd64" \
  "$("$SCRIPTS/matrix.sh" lts | jq -r '[.include[] | "\(.vendor)/\(.arch)"] | sort | join(" ")')"
assert_eq "vendor filter" "vultr/amd64" \
  "$("$SCRIPTS/matrix.sh" stable vultr | jq -r '[.include[] | "\(.vendor)/\(.arch)"] | join(" ")')"
assert_fails "gce is not in the matrix even when asked for" "$SCRIPTS/matrix.sh" stable gce
assert_eq "gce is marked as built by its own workflow" "build-gce-arm64.yml" "$(jq -r .platforms.gce.built_by "$P")"
assert_fails_with "build.sh refuses gce" "but by build-gce-arm64.yml" "$SCRIPTS/build.sh" stable 4757.2.3 arm64 gce "$T/o"
assert_fails "upcloud-only lts matrix is empty and fails" "$SCRIPTS/matrix.sh" lts upcloud
assert_fails "bad channel is rejected" "$SCRIPTS/matrix.sh" "stable;x"
assert_fails_with "build refuses upcloud on lts" "Ignition" "$SCRIPTS/build.sh" lts 4081.3.12 amd64 upcloud "$T/o"
assert_fails_with "build refuses vultr arm64" "not built for arm64" "$SCRIPTS/build.sh" stable 4757.2.3 arm64 vultr "$T/o"
assert_eq "no published format is over the asset limit by config" "0" "$(jq '[.platforms[].formats[] | select(.kind=="raw" and .publish)] | length' "$P")"
finish
