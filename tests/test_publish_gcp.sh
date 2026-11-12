#!/usr/bin/env bash
# publish-gcp.sh against a stub gcloud (no network, no credentials): a state
# directory holds the "images" and "objects" of the stub project, calls.log
# every call.
source "$(dirname "$0")/lib.sh"
require_tools jq sha256sum

stub=$T/gcloud
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
# Fake gcloud. State in $STUB_DIR: images/<name> (status), objects/<name>, calls.log, creates.
d=$STUB_DIR
echo "$*" >>"$d/calls.log"
case "$1 $2 $3" in
  "compute images describe")
    if [[ -f $d/images/$4 ]]; then
      [[ -n ${STUB_WARN:-} ]] && echo "WARNING: some gcloud notice" >&2
      cat "$d/images/$4"; exit 0
    fi
    echo "ERROR: (gcloud.compute.images.describe) Could not fetch resource: - The resource 'projects/p/global/images/$4' was not found" >&2
    exit 1 ;;
  "compute images create")
    n=$(($(cat "$d/creates" 2>/dev/null || echo 0) + 1)); echo "$n" >"$d/creates"
    if [[ $n -le ${STUB_RATE_LIMITS:-0} ]]; then
      if [[ -n ${STUB_RATE_OPERATION:-} ]]; then
        echo "ERROR: (gcloud.compute.images.create) Could not fetch resource: - Operation rate exceeded for resource 'projects/p/global/images/$4'. Too frequent operations from the source resource." >&2
      else
        echo "ERROR: (gcloud.compute.images.create) Could not fetch resource: - Quota exceeded: rateLimitExceeded" >&2
      fi
      exit 1
    fi
    if [[ -n ${STUB_CREATE_ERROR:-} ]]; then echo "ERROR: $STUB_CREATE_ERROR" >&2; exit 1; fi
    echo READY >"$d/images/$4"; exit 0 ;;
  "compute images delete") rm -f "$d/images/$4"; exit 0 ;;
  "compute images add-iam-policy-binding") exit 0 ;;
  "storage cp "*) cp "$3" "$d/objects/$(basename "$4")"; exit 0 ;;
  "storage rm "*) [[ -n ${STUB_RM_FAILS:-} ]] && exit 1; rm -f "$d/objects/$(basename "$3")"; exit 0 ;;
esac
echo "unexpected gcloud call: $*" >&2; exit 2
STUB
chmod +x "$stub"

export GCLOUD=$stub GCP_PROJECT_ID=test-project-1 GCP_BUCKET=test-bucket GCP_STORAGE_LOCATION=us
export RETRY_SLEEP=0 RETRY_MAX=3 POLL_MAX=2
NAME=flatcar-stable-1-2-3-arm64
art=$T/art; mkdir "$art"
ARTIFACT=flatcar-gce-stable-1.2.3-arm64.tar.gz
printf 'tarball\n' >"$art/$ARTIFACT"
(cd "$art" && sha256sum "$ARTIFACT" >SHA256SUMS)
export ARTIFACT_DIR=$art

fresh() { rm -rf "$T/s"; mkdir -p "$T/s/images" "$T/s/objects"; export STUB_DIR=$T/s; unset STUB_RATE_LIMITS STUB_RATE_OPERATION STUB_CREATE_ERROR STUB_RM_FAILS STUB_WARN; }
calls() { cat "$T/s/calls.log"; }
run() { "$SCRIPTS/publish-gcp.sh" "$@"; }

echo "-- fresh publication"
fresh
assert_ok "publishes" run stable 1.2.3
assert_eq "image exists" READY "$(cat "$T/s/images/$NAME")"
assert_ok "uploaded to the bucket" grep -q "^storage cp .*/$ARTIFACT gs://test-bucket/import/$NAME.tar.gz " "$T/s/calls.log"
create=$(grep '^compute images create' "$T/s/calls.log")
assert_ok "create: ARM64" grep -q -- '--architecture=ARM64' <<<"$create"
assert_ok "create: guest OS features" grep -q -- '--guest-os-features=UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE,GVNIC' <<<"$create"
assert_ok "create: family" grep -q -- '--family=flatcar-stable-arm64' <<<"$create"
assert_ok "create: labels" grep -q -- '--labels=flatcar-channel=stable,flatcar-version=1-2-3,built-by=spare-cores' <<<"$create"
assert_ok "create: storage location" grep -q -- '--storage-location=us' <<<"$create"
assert_ok "create: source uri" grep -q -- "--source-uri=gs://test-bucket/import/$NAME.tar.gz" <<<"$create"
assert_ok "create: project" grep -q -- '--project=test-project-1' <<<"$create"
assert_ok "shared with allAuthenticatedUsers" grep -q "^compute images add-iam-policy-binding $NAME --member=allAuthenticatedUsers --role=roles/compute.imageUser" "$T/s/calls.log"
assert_eq "uploaded object deleted" "" "$(ls "$T/s/objects")"

echo "-- idempotent"
: >"$T/s/calls.log"
assert_ok "second run succeeds" run stable 1.2.3
assert_eq "no second creation" "1" "$(cat "$T/s/creates")"
assert_fails "no upload" grep -q '^storage' "$T/s/calls.log"
assert_ok "sharing is ensured again" grep -q 'add-iam-policy-binding' "$T/s/calls.log"

echo "-- revision"
fresh
cp "$art/$ARTIFACT" "$art/flatcar-gce-stable-1.2.3-r2-arm64.tar.gz"
(cd "$art" && sha256sum "$ARTIFACT" flatcar-gce-stable-1.2.3-r2-arm64.tar.gz >SHA256SUMS)
assert_ok "revision" run stable 1.2.3 r2
assert_ok "revision: the artifact with the revision in its name is uploaded" grep -q "^storage cp .*/flatcar-gce-stable-1.2.3-r2-arm64.tar.gz gs://test-bucket/import/flatcar-stable-1-2-3-arm64-r2.tar.gz " "$T/s/calls.log"
assert_eq "image name has the revision" READY "$(cat "$T/s/images/flatcar-stable-1-2-3-arm64-r2" 2>/dev/null)"

echo "-- resume a half-run"
fresh; echo FAILED >"$T/s/images/$NAME"
assert_ok "failed image is recreated" run stable 1.2.3
assert_ok "failed image deleted first" grep -q "^compute images delete $NAME " "$T/s/calls.log"
assert_eq "recreated" READY "$(cat "$T/s/images/$NAME")"
fresh; echo READY >"$T/s/images/$NAME"
run stable 1.2.3 2>/dev/null
assert_ok "unshared ready image is shared, not recreated" grep -q add-iam-policy-binding "$T/s/calls.log"
assert_fails "no create for a ready image" grep -q '^compute images create' "$T/s/calls.log"
fresh; echo FAILED >"$T/s/images/$NAME"; export STUB_WARN=1
assert_ok "a gcloud warning on stderr does not hide a FAILED status" run stable 1.2.3
assert_eq "recreated despite the warning" READY "$(cat "$T/s/images/$NAME")"
fresh; echo PENDING >"$T/s/images/$NAME"
assert_fails_with "stuck PENDING image fails after the polls" 'still PENDING' run stable 1.2.3

echo "-- rate limit"
fresh; export STUB_RATE_LIMITS=2
assert_ok "retried until it works" run stable 1.2.3
assert_eq "three create calls" "3" "$(cat "$T/s/creates")"
fresh; export STUB_RATE_LIMITS=1 STUB_RATE_OPERATION=1
assert_ok "RESOURCE_OPERATION_RATE_EXCEEDED wording is retried" run stable 1.2.3
assert_eq "two create calls" "2" "$(cat "$T/s/creates")"
fresh; export STUB_RATE_LIMITS=9
assert_fails_with "gives up after RETRY_MAX" 'still rate limited after 3 attempts' run stable 1.2.3
assert_fails "no sharing without an image" grep -q add-iam-policy-binding "$T/s/calls.log"
fresh; export STUB_CREATE_ERROR="permission denied"
assert_fails_with "other errors are not retried" 'permission denied' run stable 1.2.3
assert_eq "one create call" "1" "$(cat "$T/s/creates")"

echo "-- failure to delete the object only warns"
fresh; export STUB_RM_FAILS=1
assert_ok "still succeeds" run stable 1.2.3

echo "-- integrity and input"
fresh; printf 'x\n' >>"$art/$ARTIFACT"
assert_fails_with "tampered artifact is refused" 'does not match SHA256SUMS' run stable 1.2.3
assert_fails "no image after a refused artifact" test -e "$T/s/images/$NAME"
printf 'tarball\n' >"$art/$ARTIFACT"
assert_fails "bad channel" run nope 1.2.3
assert_fails "bad version" run stable 1.2
assert_fails "bad revision" run stable 1.2.3 x2
assert_fails_with "missing config" 'must be set' env -u GCP_BUCKET "$SCRIPTS/publish-gcp.sh" stable 1.2.3
assert_fails_with "bad project id" 'invalid GCP_PROJECT_ID' env GCP_PROJECT_ID='X;rm' "$SCRIPTS/publish-gcp.sh" stable 1.2.3

echo "-- dry run"
fresh
out=$(run --dry-run stable 1.2.3 2>/dev/null)
assert_ok "dry run succeeds with no state" test -n "$out"
assert_fails "dry run calls no gcloud" test -e "$T/s/calls.log"
assert_eq "dry run prints upload, create, delete, share" "4" "$(grep -c '^+ gcloud' <<<"$out")"
assert_ok "dry run create has ARM64" grep -q 'images create .*--architecture=ARM64' <<<"$out"
out=$(env -u ARTIFACT_DIR DRY_RUN=1 "$SCRIPTS/publish-gcp.sh" stable 1.2.3 2>/dev/null)
assert_ok "DRY_RUN=1 needs no artifact or download" grep -q 'add-iam-policy-binding' <<<"$out"
finish
