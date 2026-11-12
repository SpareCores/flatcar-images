#!/usr/bin/env bash
# Publish the GCE arm64 artifact of a release as a public Compute Engine image.
#
# usage: publish-gcp.sh [--dry-run] CHANNEL VERSION [REVISION]
#
# Image flatcar-<channel>-<major>-<minor>-<patch>-arm64 (with -rN for a release
# revision), family flatcar-<channel>-arm64, labels flatcar-channel,
# flatcar-version (dots as dashes) and built-by=spare-cores, shared with
# allAuthenticatedUsers (roles/compute.imageUser).
#
# Idempotent and resumable, every step checks what is there:
#   image READY    -> nothing to create; the sharing is still ensured
#   image FAILED   -> deleted and created again
#   image PENDING  -> waited for (an earlier run may still be creating it)
#   no image       -> upload, create, then delete the uploaded object
# A half-run therefore finishes on the next run: an uploaded object is
# overwritten, an image that exists but is not shared gets shared.
# The uploaded object is deleted once the image exists (the image holds its own
# copy; the release keeps the artifact). If the delete fails, only a warning is
# printed and the bucket lifecycle rule (docs/gcp-setup.md) removes it.
#
# Google allows one image creation per 10 minutes from one source (a burst of
# six per hour). A rate-limit error is retried with doubling sleeps;
# publish-gcp.yml serialises runs with a concurrency group.
#
# Env (all required except the last ones):
#   GCP_PROJECT_ID, GCP_BUCKET, GCP_STORAGE_LOCATION (a multi-region such as
#   "us", "eu", "asia", or a region)
#   ARTIFACT_DIR       directory with the artifact and SHA256SUMS (the workflow
#                      verifies the signatures there); default: download from
#                      the release of this repository into a temp directory
#   GCLOUD             gcloud command (default gcloud; tests use a stub)
#   RETRY_MAX          create attempts on a rate-limit error (default 6)
#   RETRY_SLEEP        first sleep in seconds, doubled each time (default 120)
#   POLL_MAX           checks of a PENDING image, RETRY_SLEEP/4 apart (default 30)
# --dry-run (or DRY_RUN=1) prints the gcloud commands of a fresh publication
# and runs nothing: no gcloud call, no download.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dry=${DRY_RUN:-0}
if [[ ${1:-} == --dry-run ]]; then dry=1; shift; fi
[[ $# -ge 2 && $# -le 3 ]] || die "usage: publish-gcp.sh [--dry-run] CHANNEL VERSION [REVISION]"
channel=$1 version=$2 revision=${3:-}
valid_channel "$channel"; valid_version "$version"
[[ $revision =~ ^(r[0-9]+)?$ ]] || die "invalid revision: $revision"

project=${GCP_PROJECT_ID:-} bucket=${GCP_BUCKET:-} location=${GCP_STORAGE_LOCATION:-}
[[ -n $project && -n $bucket && -n $location ]] ||
  die "GCP_PROJECT_ID, GCP_BUCKET and GCP_STORAGE_LOCATION must be set"
[[ $project =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "invalid GCP_PROJECT_ID"
[[ $bucket =~ ^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$ ]] || die "invalid GCP_BUCKET"
[[ $location =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "invalid GCP_STORAGE_LOCATION"
gcloud_cmd=${GCLOUD:-gcloud}
retry_max=${RETRY_MAX:-6} retry_sleep=${RETRY_SLEEP:-120} poll_max=${POLL_MAX:-30}
need jq sha256sum

dashed=${version//./-}
name=flatcar-$channel-$dashed-arm64${revision:+-$revision}
family=flatcar-$channel-arm64
labels=flatcar-channel=$channel,flatcar-version=$dashed,built-by=spare-cores
object=import/$name.tar.gz
uri=gs://$bucket/$object
artifact=$(artifact_name gce "$channel" "$version" arm64 tar.gz "$revision")
tag=$(release_tag "$channel" "$version" "$revision")

# gc ARGS...: gcloud against the project.
gc() { "$gcloud_cmd" "$@" --project="$project" --quiet; }
# step ARGS...: a gcloud call that changes something; printed, not run, in a dry run.
step() {
  if [[ $dry == 1 ]]; then printf '+ gcloud %s --project=%s\n' "$*" "$project"; else gc "$@" >&2; fi
}

# image_status: prints READY, FAILED, PENDING, ... or nothing if there is no image.
# stderr is kept apart so that a gcloud warning is never read as the status.
image_status() {
  local out err errfile
  errfile=$(mktemp)
  if out=$(gc compute images describe "$name" --format='value(status)' 2>"$errfile"); then
    rm -f "$errfile"
    printf '%s\n' "$out"
    return 0
  fi
  err=$(<"$errfile"); rm -f "$errfile"
  if grep -qiE 'was not found|notFound|NOT_FOUND' <<<"$err"; then
    return 0
  fi
  die "cannot read image $name: $err"
}

# Compute Engine reports RESOURCE_OPERATION_RATE_EXCEEDED ("Operation rate exceeded ...
# Too frequent operations from the source resource") and rateLimitExceeded (403).
rate_limited() { grep -qiE 'rateLimitExceeded|RATE_LIMIT_EXCEEDED|RATE_EXCEEDED|rate exceeded|too frequent operations|rate limit|too many requests|\b429\b' <<<"$1"; }

status=
if [[ $dry != 1 ]]; then
  status=$(image_status)
  polls=0
  while [[ $status == PENDING* ]]; do
    ((++polls <= poll_max)) || die "image $name is still PENDING after $poll_max checks"
    log "image $name is PENDING (another run is creating it), waiting"
    sleep $((retry_sleep / 4))
    status=$(image_status)
  done
  if [[ $status == FAILED* ]]; then
    log "image $name is FAILED from an earlier run: deleting it"
    gc compute images delete "$name" >&2
    status=
  fi
fi

if [[ -n $status ]]; then
  log "image $name exists ($status): not creating it"
else
  if [[ $dry == 1 ]]; then
    workdir=
    log "dry run: $name from $artifact (release $tag), nothing is run"
  else
    if [[ -n ${ARTIFACT_DIR:-} ]]; then
      workdir=$ARTIFACT_DIR
    else
      need curl
      workdir=$(mktemp -d)
      trap 'rm -rf "$workdir"' EXIT
      base=https://github.com/$REPOSITORY/releases/download/$tag
      download "$base/SHA256SUMS" "$workdir/SHA256SUMS"
      download "$base/$artifact" "$workdir/$artifact"
    fi
    [[ -f $workdir/$artifact ]] || die "no $artifact in $workdir"
    [[ -f $workdir/SHA256SUMS ]] || die "no SHA256SUMS in $workdir"
    (cd "$workdir" && grep -F -- "  $artifact" SHA256SUMS | sha256sum --check --quiet) ||
      die "$artifact does not match SHA256SUMS"
  fi

  # Overwrites an object left by a failed earlier run.
  step storage cp "${workdir:+$workdir/}$artifact" "$uri"

  attempt=1 delay=$retry_sleep
  while :; do
    if [[ $dry == 1 ]]; then
      step compute images create "$name" --source-uri="$uri" --architecture=ARM64 \
        --guest-os-features=UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE,GVNIC \
        --family="$family" --labels="$labels" --storage-location="$location" \
        --description="Flatcar $channel $version arm64, OEM id gce, built by SpareCores/flatcar-images"
      break
    fi
    if out=$(gc compute images create "$name" --source-uri="$uri" --architecture=ARM64 \
      --guest-os-features=UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE,GVNIC \
      --family="$family" --labels="$labels" --storage-location="$location" \
      --description="Flatcar $channel $version arm64, OEM id gce, built by SpareCores/flatcar-images" 2>&1); then
      break
    fi
    rate_limited "$out" || die "creating image $name failed: $out"
    ((attempt < retry_max)) || die "creating image $name still rate limited after $attempt attempts: $out"
    log "image creation is rate limited (attempt $attempt of $retry_max), sleeping ${delay}s"
    sleep "$delay"
    delay=$((delay * 2)); attempt=$((attempt + 1))
    # An earlier attempt may have got through after all.
    status=$(image_status)
    [[ $status == READY* ]] && break
  done

  # The image holds its own copy; a failure here is not worth failing the run.
  if [[ $dry == 1 ]]; then
    step storage rm "$uri"
  else
    gc storage rm "$uri" >&2 || log "warning: could not delete $uri (the bucket lifecycle rule removes it)"
  fi
fi

# allUsers is refused for images; allAuthenticatedUsers is what makes it launchable by name.
step compute images add-iam-policy-binding "$name" \
  --member=allAuthenticatedUsers --role=roles/compute.imageUser
log "published $name (family $family)"
