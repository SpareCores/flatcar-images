# GCP setup (one time, by the owner)

`publish-gcp.yml` publishes the Flatcar arm64 image of each release as a public Compute Engine image (`flatcar-<channel>-<major>-<minor>-<patch>-arm64`, family `flatcar-<channel>-arm64`) in a GCP project you own, shared with `allAuthenticatedUsers`. Nothing is published, and the workflow skips with a notice, until the five repository variables below are set. No service account key and no secret is ever stored: GitHub Actions exchanges its OIDC token for short-lived credentials (workload identity federation).

None of the commands below has been run by this repository's authors against a live project: the first run is yours. Read them first.

`scripts/setup-gcp.sh` prints all of them; `--apply` runs them (as the logged-in `gcloud` user, who must own the project):

```sh
export GCP_PROJECT_ID=<your-project-id> GCP_BUCKET=<globally-unique-bucket-name> GCP_STORAGE_LOCATION=us
scripts/setup-gcp.sh           # print the commands
scripts/setup-gcp.sh --apply   # run them
```

## What it creates

1. **APIs**: Compute Engine, Cloud Storage, IAM, IAM Credentials, Security Token Service, Cloud Resource Manager.
2. **Bucket** `gs://$GCP_BUCKET` in the multi-region `$GCP_STORAGE_LOCATION` (`us`, `eu` or `asia`; keep the image's storage location and the bucket in the same multi-region): uniform bucket-level access, public access prevention, soft delete off, and a lifecycle rule that deletes objects under `import/` after one day. The script deletes the uploaded object itself once the image exists; the lifecycle rule is the backstop for a failed run.
3. **Service account** `flatcar-images-publisher` with the least privilege the workflow needs, in two parts:
   - a project **custom role** `flatcarImagePublisher` with `compute.images.create`, `get`, `delete`, `getIamPolicy`, `setIamPolicy`, `setLabels` (images.insert requires it when labels are set) and `compute.globalOperations.get`. The predefined `roles/compute.storageAdmin` would also work but adds disks and snapshots; the custom role is narrower. GCP cannot limit image permissions to one image name in advance (the images do not exist yet), so the role is project-wide; the project should hold nothing else of value, which is the intended layout;
   - `roles/storage.objectAdmin` on **this bucket only** (upload, overwrite, read for the import, delete).
4. **Workload identity pool and provider** (OIDC issuer `https://token.actions.githubusercontent.com`) with the attribute condition

   ```
   assertion.repository == "SpareCores/flatcar-images" && assertion.ref == "refs/heads/main" &&
   assertion.job_workflow_ref == "SpareCores/flatcar-images/.github/workflows/publish-gcp.yml@refs/heads/main"
   ```

   so only the `publish-gcp` workflow file on `main` of that repository gets a token: a fork, another branch, a pull request or another workflow of the same repository cannot. For a fork of this repository, set `GITHUB_REPO` to the fork.
5. The **binding**: the service account's `roles/iam.workloadIdentityUser` for the pool's `attribute.repository/SpareCores/flatcar-images` principal set.

## Repository variables

Settings, Secrets and variables, Actions, **Variables** (not secrets; none of them is sensitive). The script prints the values.

| Variable | Value |
|---|---|
| `GCP_PROJECT_ID` | the project ID |
| `GCP_BUCKET` | the bucket name |
| `GCP_STORAGE_LOCATION` | `us`, `eu`, `asia` or a region: where the image is stored |
| `GCP_SERVICE_ACCOUNT` | `flatcar-images-publisher@<project>.iam.gserviceaccount.com` |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<project number>/locations/global/workloadIdentityPools/github/providers/flatcar-images` |

## Things to check before the first run

- **Organization policy.** Sharing with `allAuthenticatedUsers` is refused when `constraints/iam.allowedPolicyMemberDomains` (domain restricted sharing) applies to the project. Allow all values for this project, or use a project in a folder without the constraint.
- **Quota and rate.** Google allows one image creation per 10 minutes from one source. `publish-gcp.yml` runs one at a time (`concurrency` group `publish-gcp`, never cancelled) and `publish-gcp.sh` retries a rate-limit error with doubling sleeps. GitHub keeps only one waiting run per group: if several releases land together, dispatch the workflow again for the one that was dropped. It is safe to repeat: an existing image is not created again.
- **Cost.** Images are billed on their compressed size and are kept (nothing is deleted automatically); the bucket holds nothing between runs.

## First run

Run the `publish-gcp` workflow by hand (Actions, publish-gcp, Run workflow) with an existing release (channel, version, empty revision). The log shows the image name; `gcloud compute images describe flatcar-<channel>-<major>-<minor>-<patch>-arm64 --project=<project>` shows it, and the same command works from any other signed-in Google account, which proves the sharing. Booting the image is not part of this repository: see the README status table.

## Undo

Delete the images (`gcloud compute images delete`), the bucket, the service account, the custom role, the provider and the pool (`gcloud iam workload-identity-pools delete`), and unset the repository variables.
