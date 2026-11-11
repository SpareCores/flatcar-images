#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_tools jq curl

srv=$T/srv
for c in stable lts beta alpha; do
  mkdir -p "$srv/$c/amd64-usr/current"
done
echo 'FLATCAR_VERSION=4757.2.3' >"$srv/stable/amd64-usr/current/version.txt"
echo 'FLATCAR_VERSION=4081.3.12' >"$srv/lts/amd64-usr/current/version.txt"
echo 'FLATCAR_VERSION=4820.1.1' >"$srv/beta/amd64-usr/current/version.txt"
export FLATCAR_RELEASE_BASE=file://$srv

printf 'stable-4757.2.2\nlts-4081.3.11\n' >"$T/tags"
assert_eq "new stable and lts releases are found; beta and alpha are not tracked" \
  "lts 4081.3.12
stable 4757.2.3" "$("$SCRIPTS/track.sh" --tags "$T/tags" 2>/dev/null | sort)"
printf 'stable-4757.2.3\nlts-4081.3.12-r2\n' >"$T/tags"
assert_eq "released versions (also with a revision suffix) are not rebuilt" "" "$("$SCRIPTS/track.sh" --tags "$T/tags" 2>/dev/null)"
printf 'stable-4757.2.30\n' >"$T/tags"
assert_eq "tag prefix of another version does not count" "stable 4757.2.3" "$("$SCRIPTS/track.sh" --tags "$T/tags" 2>/dev/null | grep ^stable)"
echo 'FLATCAR_VERSION=garbage' >"$srv/stable/amd64-usr/current/version.txt"
assert_fails "garbage version.txt fails" "$SCRIPTS/track.sh" --tags "$T/tags"
finish
