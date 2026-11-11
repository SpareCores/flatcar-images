#!/usr/bin/env bash
# One-time setup of the GCP project that publishes the GCE arm64 images
# (docs/gcp-setup.md). Prints the gcloud commands; runs them only with --apply.
#
# usage: setup-gcp.sh [--apply]
#
# Env: GCP_PROJECT_ID and GCP_BUCKET (required), GCP_STORAGE_LOCATION (default
# us), GITHUB_REPO (default SpareCores/flatcar-images), SA_NAME (default
# flatcar-images-publisher), POOL_ID (default github), PROVIDER_ID (default
# flatcar-images), ROLE_ID (default flatcarImagePublisher).
# Run it as an owner of the project, logged in with `gcloud auth login`. It
# makes no change without --apply and creates no key.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

apply=0
case ${1:-} in
  --apply) apply=1 ;;
  "") ;;
  *) die "usage: setup-gcp.sh [--apply]" ;;
esac

project=${GCP_PROJECT_ID:-} bucket=${GCP_BUCKET:-} location=${GCP_STORAGE_LOCATION:-us}
repo=${GITHUB_REPO:-$REPOSITORY} sa=${SA_NAME:-flatcar-images-publisher}
pool=${POOL_ID:-github} provider=${PROVIDER_ID:-flatcar-images} role=${ROLE_ID:-flatcarImagePublisher}
[[ -n $project && -n $bucket ]] || die "GCP_PROJECT_ID and GCP_BUCKET must be set"
[[ $project =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "invalid GCP_PROJECT_ID"
[[ $bucket =~ ^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$ ]] || die "invalid GCP_BUCKET"
[[ $location =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "invalid GCP_STORAGE_LOCATION"
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid GITHUB_REPO"
[[ $sa =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "invalid SA_NAME"
[[ $pool =~ ^[a-z][a-z0-9-]{2,30}[a-z0-9]$ && $provider =~ ^[a-z][a-z0-9-]{2,30}[a-z0-9]$ ]] || die "invalid POOL_ID or PROVIDER_ID"
[[ $role =~ ^[A-Za-z0-9_.]{3,64}$ ]] || die "invalid ROLE_ID"
sa_email=$sa@$project.iam.gserviceaccount.com
perms=compute.images.create,compute.images.get,compute.images.delete,compute.images.getIamPolicy,compute.images.setIamPolicy,compute.globalOperations.get
cond="assertion.repository == \"$repo\" && assertion.ref == \"refs/heads/main\" && assertion.job_workflow_ref == \"$repo/.github/workflows/publish-gcp.yml@refs/heads/main\""

steps=()
add() { steps+=("$1"); }
add "gcloud services enable compute.googleapis.com storage.googleapis.com iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com cloudresourcemanager.googleapis.com --project=$project"
add "gcloud storage buckets create gs://$bucket --project=$project --location=$location --uniform-bucket-level-access --public-access-prevention --soft-delete-duration=0"
add "printf '%s\n' '{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"age\":1,\"matchesPrefix\":[\"import/\"]}}]}' >\"\${TMPDIR:-/tmp}/flatcar-lifecycle.json\" && gcloud storage buckets update gs://$bucket --project=$project --lifecycle-file=\"\${TMPDIR:-/tmp}/flatcar-lifecycle.json\""
add "gcloud iam service-accounts create $sa --project=$project --display-name='Flatcar images publisher'"
add "gcloud iam roles create $role --project=$project --title='Flatcar image publisher' --stage=GA --permissions=$perms"
add "gcloud projects add-iam-policy-binding $project --member=serviceAccount:$sa_email --role=projects/$project/roles/$role --condition=None"
add "gcloud storage buckets add-iam-policy-binding gs://$bucket --member=serviceAccount:$sa_email --role=roles/storage.objectAdmin"
add "gcloud iam workload-identity-pools create $pool --project=$project --location=global --display-name='GitHub Actions'"
add "gcloud iam workload-identity-pools providers create-oidc $provider --project=$project --location=global --workload-identity-pool=$pool --issuer-uri=https://token.actions.githubusercontent.com --attribute-mapping='google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.job_workflow_ref=assertion.job_workflow_ref' --attribute-condition='$cond'"
add "gcloud iam service-accounts add-iam-policy-binding $sa_email --project=$project --role=roles/iam.workloadIdentityUser --member=\"principalSet://iam.googleapis.com/projects/\$(gcloud projects describe $project --format='value(projectNumber)')/locations/global/workloadIdentityPools/$pool/attribute.repository/$repo\""

if [[ $apply == 1 ]]; then
  need gcloud
  for s in "${steps[@]}"; do
    log "+ $s"
    eval "$s"
  done
  number=$(gcloud projects describe "$project" --format='value(projectNumber)')
  echo "Done. Set these repository variables in $repo (Settings, Secrets and variables, Actions, Variables):"
else
  printf '# Dry run: nothing is executed. Review, then run with --apply (or paste the commands).\n'
  printf '%s\n' "${steps[@]}"
  number=PROJECT_NUMBER
  printf '\n# Then set these repository variables in %s:\n' "$repo"
fi
cat <<VARS
GCP_PROJECT_ID=$project
GCP_BUCKET=$bucket
GCP_STORAGE_LOCATION=$location
GCP_SERVICE_ACCOUNT=$sa_email
GCP_WORKLOAD_IDENTITY_PROVIDER=projects/$number/locations/global/workloadIdentityPools/$pool/providers/$provider
VARS
