#!/usr/bin/env bash
# setup-gcp.sh prints by default and runs gcloud only with --apply (stub gcloud).
source "$(dirname "$0")/lib.sh"
require_tools jq

mkdir "$T/bin"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "$*" >>"%s/calls.log"\n[[ $1 == projects && $2 == describe ]] && echo 123456\nexit 0\n' "$T" >"$T/bin/gcloud"
chmod +x "$T/bin/gcloud"
export PATH=$T/bin:$PATH GCP_PROJECT_ID=test-project-1 GCP_BUCKET=test-bucket

out=$("$SCRIPTS/setup-gcp.sh" 2>/dev/null)
assert_fails "default run calls no gcloud" test -e "$T/calls.log"
assert_ok "prints the repository restriction" grep -qF 'assertion.repository == "SpareCores/flatcar-images"' <<<"$out"
assert_ok "prints the main branch and workflow restriction" grep -qF 'publish-gcp.yml@refs/heads/main' <<<"$out"
assert_ok "prints the variables" grep -q '^GCP_WORKLOAD_IDENTITY_PROVIDER=projects/PROJECT_NUMBER/' <<<"$out"
assert_ok "role can set labels (images.insert with labels needs it)" grep -q "compute.images.setLabels" <<<"$out"
assert_fails "no service account key is created" grep -q 'keys create' <<<"$out"
assert_ok "--apply runs the commands" "$SCRIPTS/setup-gcp.sh" --apply
assert_ok "apply created the pool" grep -q '^iam workload-identity-pools create' "$T/calls.log"
assert_fails_with "unknown argument" usage "$SCRIPTS/setup-gcp.sh" --yes
assert_fails_with "bad project id" 'invalid GCP_PROJECT_ID' env GCP_PROJECT_ID='a;b' "$SCRIPTS/setup-gcp.sh"
finish
