# GCP project: what `publish-gcp.yml` expects

`publish-gcp.yml` publishes the Flatcar arm64 image of each release as a public Compute Engine image (`flatcar-<channel>-<major>-<minor>-<patch>-arm64`, family `flatcar-<channel>-arm64`) in a GCP project, shared with `allAuthenticatedUsers`. The Spare Cores project is managed in its own infrastructure code; this page only lists what the workflow needs to exist, for anyone running their own. No service account key or secret is stored: GitHub Actions exchanges its OIDC token for short-lived credentials (workload identity federation).

Until the five repository variables are set, the workflow skips with a notice.

## Repository variables

Settings, Secrets and variables, Actions, **Variables** (none is sensitive).

| Variable | Meaning |
|---|---|
| `GCP_PROJECT_ID` | ID of the project that holds the images and the bucket |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | full resource name of the workload identity provider: `projects/<number>/locations/global/workloadIdentityPools/<pool>/providers/<provider>` |
| `GCP_SERVICE_ACCOUNT` | email of the publisher service account |
| `GCP_BUCKET` | name of the bucket used for the temporary import upload |
| `GCP_STORAGE_LOCATION` | where the image is stored: a multi-region (`us`, `eu`, `asia`) or a region; keep it in the same multi-region as the bucket |

## APIs

Compute Engine, Cloud Storage, IAM, IAM Credentials, Security Token Service, Cloud Resource Manager.

## Bucket

- uniform bucket-level access (public access prevention and soft delete off are recommended);
- lifecycle rule deleting objects under `import/` after 1 day. The workflow deletes the uploaded object itself once the image exists; the rule is the backstop for a failed run.

## Publisher service account

- A project custom role with exactly these permissions (keep in sync with what `scripts/publish-gcp.sh` calls):
  - `compute.images.create`
  - `compute.images.get`
  - `compute.images.delete`
  - `compute.images.setLabels` (images.insert requires it when labels are set)
  - `compute.images.getIamPolicy`
  - `compute.images.setIamPolicy`
  - `compute.globalOperations.get`
- `roles/storage.objectAdmin` on the bucket only.
- `roles/iam.workloadIdentityUser` for the provider's pool, scoped to the repository principal set.

Image permissions cannot be limited to one image name in advance, so the role is project-wide: the project should hold nothing else of value.

## Workload identity provider

OIDC issuer `https://token.actions.githubusercontent.com`.

Attribute mapping:

- `google.subject` = `assertion.sub`
- `attribute.repository` = `assertion.repository`
- `attribute.repository_id` = `assertion.repository_id`
- `attribute.repository_owner_id` = `assertion.repository_owner_id`
- `attribute.ref` = `assertion.ref`
- `attribute.job_workflow_ref` = `assertion.job_workflow_ref`

Attribute condition (the repository ID and owner ID are checked as well as the name):

- `assertion.repository == "SpareCores/flatcar-images"`
- `assertion.repository_id == "<repository id>"`
- `assertion.repository_owner_id == "<owner id>"`
- `assertion.ref == "refs/heads/main"`
- `assertion.job_workflow_ref == "SpareCores/flatcar-images/.github/workflows/publish-gcp.yml@refs/heads/main"`

All must hold, so only the `publish-gcp` workflow file on `main` of this repository gets a token.

## Organization policy

Sharing with `allAuthenticatedUsers` is refused when domain restricted sharing (`constraints/iam.allowedPolicyMemberDomains`) applies. The project needs a project-level exception for it.

## Operational notes

Google allows one image creation per 10 minutes from one source. The workflow runs one publish at a time and the script retries rate-limit errors. If several releases land together, dispatch the workflow again for a dropped one; an existing image is not created again. Images are kept, billed on compressed size.
