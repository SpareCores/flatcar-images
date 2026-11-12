#!/usr/bin/env bash
# Put the GCE arm64 artifact into a release: new manifest, checksums, notes.
#
# usage: release-gce-arm64.sh assemble NEWDIR OUTDIR CHANNEL VERSION [REVISION [EXISTING_MANIFEST]]
#        release-gce-arm64.sh notes MANIFEST ARTIFACT [EXISTING_NOTES_FILE]
#
# build-gce-arm64.yml adds its artifact to the release <channel>-<version>
# that build.yml made (or makes the release if there is none), so manifest.json
# and SHA256SUMS have to cover the other artifacts of the release too.
#
# assemble: NEWDIR holds the artifact and its .meta.json (package.sh).
#   EXISTING_MANIFEST is the manifest.json of the release as it is now (omit it
#   for a release that does not exist yet). OUTDIR gets the new artifact, a
#   manifest.json in which the artifact of the same name is replaced and every
#   other artifact is kept as it was (same size, sha256, source image), and a
#   SHA256SUMS over all of them. Only the new artifact is in OUTDIR; the other
#   files of the release are untouched on GitHub. Prints "replaced" or "added"
#   on stdout: whether the manifest already listed an artifact of that name.
# notes: the release notes. Without EXISTING_NOTES_FILE the usual table
#   (release-notes.sh); with it, the existing text. Either way a section about
#   the GCE arm64 artifact is appended (it replaces one from an earlier build):
#   the fork, why, and the update warning. The table row of the artifact is
#   rewritten from the manifest (size, sha256), or added when the table has none.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
here=$(dirname "${BASH_SOURCE[0]}")

cmd=${1:-}
[[ $# -ge 1 ]] || die "usage: release-gce-arm64.sh assemble|notes ..."
shift
need jq

case $cmd in
  assemble)
    [[ $# -ge 4 && $# -le 6 ]] || die "usage: release-gce-arm64.sh assemble NEWDIR OUTDIR CHANNEL VERSION [REVISION [EXISTING_MANIFEST]]"
    newdir=$1 outdir=$2 channel=$3 version=$4 revision=${5:-} existing=${6:-}
    valid_channel "$channel"; valid_version "$version"
    [[ $revision =~ ^(r[0-9]+)?$ ]] || die "invalid revision: $revision"
    name=$(artifact_name gce "$channel" "$version" arm64 tar.gz "$revision")
    [[ -f $newdir/$name && -f $newdir/$name.meta.json ]] || die "no $name and $name.meta.json in $newdir"
    jq -e --arg n "$name" '.name == $n and .vendor == "gce" and .arch == "arm64" and .published' "$newdir/$name.meta.json" >/dev/null ||
      die "$name.meta.json does not describe the published gce arm64 artifact"
    mkdir -p "$outdir"
    [[ -z $(ls -A "$outdir") ]] || die "$outdir is not empty"
    cp "$newdir/$name" "$newdir/$name.meta.json" "$outdir/"
    result=added
    if [[ -n $existing ]]; then
      [[ -f $existing ]] || die "no such manifest: $existing"
      tag=$(release_tag "$channel" "$version" "$revision")
      jq -e --arg tag "$tag" '.schema == 1 and .tag == $tag and (.artifacts | type == "array")' "$existing" >/dev/null ||
        die "$existing is not the manifest of release $tag"
      if jq -e --arg n "$name" 'any(.artifacts[]; .name == $n)' "$existing" >/dev/null; then result=replaced; fi
      # The other artifacts become meta files again; manifest.sh adds their urls.
      while IFS= read -r line; do
        n=$(jq -r .name <<<"$line")
        [[ $n =~ ^[A-Za-z0-9._-]+$ ]] || die "unexpected artifact name in $existing: $n"
        jq 'del(.url)' <<<"$line" >"$outdir/$n.meta.json"
      done < <(jq -c --arg n "$name" '.artifacts[] | select(.name != $n)' "$existing")
    fi
    MANIFEST_PARTIAL=1 "$here/manifest.sh" "$outdir" "$channel" "$version" "$revision"
    rm -f "$outdir"/*.meta.json
    printf '%s\n' "$result"
    ;;
  notes)
    [[ $# -ge 2 && $# -le 3 ]] || die "usage: release-gce-arm64.sh notes MANIFEST ARTIFACT [EXISTING_NOTES_FILE]"
    manifest=$1 artifact=$2 old=${3:-}
    jq -e --arg n "$artifact" 'any(.artifacts[]; .name == $n and (.source.commit | type == "string"))' "$manifest" >/dev/null ||
      die "$artifact with a fork source is not in $manifest"
    if [[ -n $old ]]; then
      row=$("$here/release-notes.sh" "$manifest" "$artifact")
      # A rebuild replaces the section of the previous build instead of repeating
      # it (and the blank lines before it), and the table row of the artifact.
      sed '/^### Google Cloud arm64: built from a kernel fork$/,$d' "$old" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' |
        ROW=$row PREFIX="| \`$artifact\` |" awk '
          index($0, ENVIRON["PREFIX"]) == 1 { lines[++n] = ENVIRON["ROW"]; last = n; done = 1; next }
          { lines[++n] = $0; if (index($0, "| `") == 1) last = n }
          END {
            # a missing row goes after the last table row
            for (i = 1; i <= n; i++) {
              print lines[i]
              if (!done && i == last) { print ENVIRON["ROW"]; done = 1 }
            }
            if (!done) { print "\n| Artifact | Vendor | OEM id | Arch | Format | Size | sha256 |\n|---|---|---|---|---|---|---|"; print ENVIRON["ROW"] }
          }'
    else
      "$here/release-notes.sh" "$manifest"
    fi
    jq -r --arg n "$artifact" '
      .artifacts[] | select(.name == $n) | .source as $s |
      "\n### Google Cloud arm64: built from a kernel fork\n",
      "`\(.name)` was built by the `build-gce-arm64` workflow from [\($s.repository)@\($s.commit[0:12])](https://github.com/\($s.repository)/commit/\($s.commit)) (ref `\($s.ref)`, based on Flatcar `\($s.base_tag // "?")`), not made by setting the OEM id on the generic image: Flatcar'"'"'s arm64 kernel has no gVNIC driver, which every GCE arm64 machine type needs. An earlier artifact of the same name, which carried only the OEM id patch and could not boot on GCE, is replaced, so the checksum changed; `manifest.json`, `SHA256SUMS` and their signatures were updated and are signed by the `build-gce-arm64` workflow.",
      "\nNodes must disable Flatcar auto-updates (`update-engine`, `SERVER=disabled`): a stock update would remove the gVNIC driver. See `docs/gce-arm64.md`."' "$manifest"
    ;;
  *) die "unknown command: $cmd (assemble or notes)" ;;
esac
