# FAST practice sandbox — full build guide

A complete, step-by-step record of building a GCP landing zone with Fabric
FAST, from an empty domain to a working CI/CD pipeline. Every command here is
what was actually run, in order, against a real (throwaway) organization.
Follow it top to bottom to reproduce the same result.

**What you end up with:** a Google Cloud organization with a folder
hierarchy, org-wide security policies, isolated automation identities, and a
GitHub Actions pipeline that plans and applies changes to that organization
automatically — with no credential file anywhere.

> Every value below (org ID, project names, account emails) is the real one
> from this build, shown so you can see what a finished example looks like.
> Replace them with your own as you go — they are marked where it matters.

---

## 0. What you need before starting

| Requirement | Why |
|---|---|
| A domain name you control | Becomes your Cloud Identity / GCP organization |
| A credit card | For the GCP billing account (a free trial covers actual usage) |
| A GitHub account | Hosts the config and runs the pipeline |
| Windows with **WSL2** installed | See below — this cannot be done from native Windows |
| ~2 hours, some of it waiting on DNS/propagation | |

### Why WSL2 and not plain Windows

Terraform's `dirname()` function returns Windows-style backslashes
(`security\dev`) on native Windows, but Fabric's YAML factories split
resource paths on forward slashes to build the folder hierarchy. On Windows
this silently collapses every nested folder to the top level — it does not
error, it just builds the wrong structure. Do this from WSL2 Ubuntu or a real
Linux machine. Do not work from `/mnt/c/...` either; clone everything into
the Linux home directory.

---

## 1. Get an organization: Cloud Identity Free

A GCP **organization** only exists if your domain is registered with Google
Workspace or Cloud Identity. This step creates that.

1. Go to **workspace.google.com/gcpidentity/signup?sku=identitybasic**
2. Enter your domain and create an admin user (this build used
   `lab@bilalnagina.com`).
3. Verify domain ownership. If your registrar (GoDaddy, in this build) is
   already linked to the account signing up, verification can complete
   automatically without a manual DNS record — check the Admin Console under
   **Domains** to confirm it's verified before continuing.
4. Signing up **auto-creates a GCP organization** for the domain. Confirm it
   exists:

   ```bash
   gcloud auth login lab@bilalnagina.com
   gcloud organizations list \
     --format="table(displayName, ID, owner.directoryCustomerId)"
   ```

   Real output from this build:

   ```
   DISPLAY_NAME       ID              DIRECTORY_CUSTOMER_ID
   bilalnagina.com    287552611155    C00l7b6x7
   ```

   **Write down the ID and customer ID** — both go into config later.

---

## 2. Create the admin group and billing account

### 2.1 Admin group

FAST grants organization-wide permissions to a **group**, never to an
individual user. Create it before doing anything else, and put yourself in
it, or the first Terraform apply will hand control to an empty group and
lock you out.

In **admin.google.com** → Directory → Groups → Create group:

- Email: `gcp-organization-admins@<your-domain>`
- Add your admin user as a member

### 2.2 Billing account

At **console.cloud.google.com/billing**, signed in as the admin user:
create a new billing account, take the free trial credit if offered.

```bash
gcloud beta billing accounts list
```

Real output from this build:

```
ACCOUNT_ID            NAME                OPEN
01C191-EEC543-6C1024  My Billing Account  True
```

**`OPEN` must say `True`.** If it says `False`, the trial signup hasn't
finished activating — check the billing console for a pending confirmation
step before continuing.

---

## 3. Set up the local toolchain (inside WSL2)

Open your WSL2 Ubuntu terminal for everything from here on.

```bash
sudo apt-get update -qq
sudo apt-get install -y unzip apt-transport-https ca-certificates gnupg curl

# Terraform's official apt repo
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list

# Google Cloud's official apt repo
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list

sudo apt-get update -qq
sudo apt-get install -y terraform google-cloud-cli
```

Confirm both landed as **native Linux binaries**, not paths that resolve
into `/mnt/c/...` (a Windows install of gcloud on your `PATH` works but is
slower and keeps credentials on the wrong side of the WSL boundary):

```bash
which terraform   # /usr/bin/terraform
which gcloud      # /usr/bin/gcloud
```

Authenticate — **both** commands are required, they populate different
credential stores that gcloud and Terraform each read from:

```bash
gcloud auth login lab@bilalnagina.com
gcloud auth application-default login
```

Install the GitHub CLI too — used later to create the pull request that
verifies the pipeline:

```bash
sudo apt install gh
gh auth login
```

`gh auth login` asks for scopes. Make sure **`workflow`** is included — it's
required to push files under `.github/workflows/`, and GitHub will reject
the push later without it:

```bash
gh auth refresh -h github.com -s workflow
```

---

## 4. Clone Fabric FAST, pinned to a fixed version

Never track a moving branch — FAST's stage layout changes between releases.

```bash
mkdir -p ~/gcp_landing_zone
cd ~/gcp_landing_zone
git clone --depth 1 --branch v57.0.0 \
  https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git fabric
```

This creates `~/gcp_landing_zone/fabric/`, containing the stage code:

```
fabric/fast/stages/
├── 0-org-setup/        ← the stage this guide builds
├── 1-vpcsc/
├── 2-networking/
├── 2-project-factory/
├── 2-security/
└── 3-secops-dev/
```

**Never edit anything inside `fabric/`.** It's upstream, pinned code —
your own configuration lives in a separate `config/` directory (next
section) that references it.

---

## 5. Build your configuration

FAST reads a directory of YAML files (a **dataset**) that describes what you
want your organization to look like, and generates Terraform from it. You
never write Terraform by hand for stage 0.

### 5.1 Copy the starter dataset

Fabric ships four starter datasets under `fabric/fast/stages/0-org-setup/datasets/`.
`classic` is the one to learn on:

```bash
mkdir -p ~/gcp_landing_zone/config/0-org-setup
cp -r ~/gcp_landing_zone/fabric/fast/stages/0-org-setup/datasets/classic \
      ~/gcp_landing_zone/config/0-org-setup/dataset
```

You now have your own editable copy at
`config/0-org-setup/dataset/`, structured like this:

```
config/0-org-setup/dataset/
├── defaults.yaml              ← global settings — edit this first
├── cicd.yaml                  ← CI/CD pipeline definition — edit later
├── billing-accounts/
│   └── default.yaml
├── folders/
│   ├── networking/{dev,prod}/.config.yaml
│   ├── security/{dev,prod}/.config.yaml
│   └── teams/.config.yaml
├── organization/
│   ├── custom-roles/*.yaml    ← 9 custom IAM roles
│   ├── org-policies/*.yaml    ← 33 org-wide guardrails
│   ├── custom-constraints/*.yaml
│   └── tags/*.yaml
├── projects/core/
│   ├── iac-0.yaml              ← the automation project — edit later
│   ├── log-0.yaml               (audit logging project)
│   └── billing-0.yaml           (billing export project)
└── observability/iac-0/impersonation.yaml
```

### 5.2 Edit `defaults.yaml`

This is the one file every build must customize. Open
`config/0-org-setup/dataset/defaults.yaml` and set:

```yaml
global:
  billing_account: 01C191-EEC543-6C1024        # from step 2.2

  organization:
    domain: bilalnagina.com                     # from step 1
    id: 287552611155                             # from step 1
    customer_id: C00l7b6x7                       # from step 1

projects:
  defaults:
    # Globally unique, under 9 characters. Stamped into every project ID
    # this stage creates. Effectively permanent — changing it later means
    # a rebuild, not an edit.
    prefix: dpslab
    locations:
      bigquery: $locations:primary
      logging: $locations:primary
      storage: $locations:primary

context:
  email_addresses:
    gcp-organization-admins: gcp-organization-admins@bilalnagina.com
  iam_principals:
    # The group from step 2.1. Your admin user must already be a member.
    gcp-organization-admins: group:gcp-organization-admins@bilalnagina.com
  locations:
    # No GCP region exists in Kuwait. me-central1 (Doha) is the nearest.
    primary: me-central1
```

Everything under `output_files:` can stay as shipped — it defines where
generated provider files land for each downstream stage and doesn't need
editing for stage 0 alone.

### 5.3 Create `terraform.tfvars`

This is the file that tells the generic Fabric stage code where *your*
dataset lives. It sits outside `fabric/`, in your own `config/` tree:

**`config/0-org-setup/terraform.tfvars`**
```hcl
factories_config = {
  dataset = "../../../../config/0-org-setup/dataset"
  paths = {
    # Without this, cicd.yaml is ignored and no pipeline gets generated.
    cicd_workflows = "cicd.yaml"
  }
}

# Pre-existing org policies that collide with the ones this stage manages
# must be listed here or the first apply fails with "already exists".
# Check first: gcloud org-policies list --organization <ORG_ID>
# On a genuinely fresh org these four typically need listing:
#   iam.allowedPolicyMemberDomains
#   iam.automaticIamGrantsForDefaultServiceAccounts
#   iam.disableServiceAccountKeyUpload
#   storage.uniformBucketLevelAccess
org_policies_imports = []
```

The `dataset` path is relative to the **stage directory**
(`fabric/fast/stages/0-org-setup/`), not to this file — that's why it climbs
up four levels before descending into `config/`.

---

## 6. Grant yourself bootstrap permissions

Before the first `terraform apply` can run, the admin group needs org-level
IAM roles. Nine roles, granted once:

```bash
ORG_ID=287552611155
PRINCIPAL="group:gcp-organization-admins@bilalnagina.com"

for role in \
  roles/billing.admin \
  roles/logging.admin \
  roles/iam.organizationRoleAdmin \
  roles/orgpolicy.policyAdmin \
  roles/resourcemanager.folderAdmin \
  roles/resourcemanager.organizationAdmin \
  roles/resourcemanager.projectCreator \
  roles/resourcemanager.tagAdmin \
  roles/owner
do
  gcloud organizations add-iam-policy-binding "$ORG_ID" \
    --member "$PRINCIPAL" --role "$role" --condition None
done
```

You also need a project to run the first apply *from* — any project linked
to your billing account works, including the default one Google creates
automatically when you sign up for billing (`future-grove-506710-t2` in this
build). Enable the APIs stage 0 needs on it:

```bash
gcloud config set project <your-bootstrap-project-id>
gcloud services enable \
  bigquery.googleapis.com cloudbilling.googleapis.com \
  cloudresourcemanager.googleapis.com essentialcontacts.googleapis.com \
  iam.googleapis.com logging.googleapis.com orgpolicy.googleapis.com \
  serviceusage.googleapis.com
```

---

## 7. First apply — bootstrap with your own credentials

Stage 0 has a chicken-and-egg problem: it creates the automation identity
and the storage bucket that it's *supposed* to run on. The fix is to run it
twice. This first run uses your own user credentials and keeps its state on
local disk.

```bash
cd ~/gcp_landing_zone/fabric/fast/stages/0-org-setup
terraform init
terraform apply -var-file=../../../../config/0-org-setup/terraform.tfvars
```

Review the plan, then confirm. This creates:

- The automation project (`dpslab-prod-iac-core-0`)
- The audit-log and billing-export projects
- 7 folders (Networking, Security, Teams, and Development/Production under
  each of the first two)
- 12 automation service accounts (a read-write and read-only pair per
  future stage)
- 9 custom IAM roles
- 33 org-wide policies
- 3 GCS buckets for Terraform state and generated outputs

If it needs to retry on a transient error, that's fine — see
**Troubleshooting** at the end of this guide.

---

## 8. Migrate state to Google Cloud Storage

Apply #1 generated a provider file describing the automation identity it
just created. Pull that in, then move your Terraform state off your laptop
and into the bucket that identity controls:

```bash
cp ~/fast-config/dpslab/providers/0-org-setup-providers.tf ./
terraform init -migrate-state
```

Answer **yes** when asked to copy existing state to the new backend. The
generated file looks like this:

**`0-org-setup-providers.tf`**
```hcl
terraform {
  backend "gcs" {
    bucket                      = "dpslab-prod-iac-core-0-iac-org-state"
    impersonate_service_account = "iac-org-rw@dpslab-prod-iac-core-0.iam.gserviceaccount.com"
  }
}
provider "google" {
  impersonate_service_account = "iac-org-rw@dpslab-prod-iac-core-0.iam.gserviceaccount.com"
}
provider "google-beta" {
  impersonate_service_account = "iac-org-rw@dpslab-prod-iac-core-0.iam.gserviceaccount.com"
}
```

`impersonate_service_account` is the whole point — from the next apply
onward, Terraform acts as this service account, not as you.

---

## 9. Second apply — as the service account

```bash
unset GOOGLE_CLOUD_QUOTA_PROJECT   # if you set it earlier for bootstrap auth
terraform apply -var-file=../../../../config/0-org-setup/terraform.tfvars
```

This run authenticates as `iac-org-rw@dpslab-prod-iac-core-0`, not as your
user — Terraform asks Google to impersonate that service account and mint a
short-lived token. **From this point on, no human credential is required to
manage the organization.**

Confirm everything converged:

```bash
terraform plan -detailed-exitcode -var-file=../../../../config/0-org-setup/terraform.tfvars
```

Exit code `0` means no changes — your organization now matches your config
exactly. This build finished at **314 tracked resources**.

Stage 0 is now functionally complete. Everything from here on is optional
hardening: version control and an automated pipeline for future changes.

---

## 10. Put the configuration under version control

Nothing so far has been in git. Fix that — an unversioned directory
describing your entire organization is a single point of failure.

```bash
cd ~/gcp_landing_zone
```

**`.gitignore`**
```gitignore
# Upstream Fabric, pinned - has its own git history, reproducible via the
# clone command in section 4.
fabric/

# Terraform working files
.terraform/
*.tfstate
*.tfstate.*
tfplan.out
*.tfplan

# Generated by stage 0 on every apply - not the source of truth
*-providers.tf
```

**`.gitattributes`** — important if you ever touch these files from
Windows; without it, a Windows editor can silently convert line endings and
turn a one-line change into a several-hundred-line diff:

```gitattributes
* text=auto eol=lf
```

Then:

```bash
git init -b main
git config user.name  "<your name>"
git config user.email "<your email>"
git add -A
git commit -m "Initial commit: FAST 0-org-setup config"
```

---

## 11. Wire up CI/CD with Workload Identity Federation

The goal: a GitHub Actions pipeline that runs `terraform plan` on every pull
request and `terraform apply` on every merge to `main` — authenticating to
Google Cloud with **no service account key file, ever**. GitHub proves who
it is with a signed token; Google checks that token against a trust
condition and issues a short-lived credential.

### 11.1 Create the GitHub repository

Create an empty **private** repo (no README, no `.gitignore` from GitHub —
you already have both) and note its `owner/name`, e.g.
`BilalNagina/gcp_landing_zone`.

### 11.2 Enable the Workload Identity pool

Open `config/0-org-setup/dataset/projects/core/iac-0.yaml`. Near the bottom,
uncomment (or add) this block, substituting your GitHub username or
organization:

```yaml
workload_identity_pools:
  default:
    display_name: Default pool for CI/CD.
    providers:
      github-default:
        display_name: GitHub (BilalNagina).
        # Only tokens issued to repositories owned by this account are trusted.
        attribute_condition: attribute.repository_owner=="BilalNagina"
        identity_provider:
          oidc:
            template: github
```

### 11.3 Point `cicd.yaml` at your repository

Edit `config/0-org-setup/dataset/cicd.yaml`:

```yaml
org-setup:
  provider_files:
    apply: 0-org-setup-providers.tf
    plan: 0-org-setup-ro-providers.tf
  repository:
    name: BilalNagina/gcp_landing_zone
    type: github
    apply_branches:
      - main
  service_accounts:
    apply: $iam_principals:service_accounts/iac-0/iac-org-cicd-rw
    plan: $iam_principals:service_accounts/iac-0/iac-org-cicd-ro
  tfvars_files:
    - 0-org-setup.auto.tfvars
  workload_identity:
    pool: $workload_identity_pools:iac-0/default
    provider: $workload_identity_providers:iac-0/default/github-default
    iam_principalsets:
      template: github
```

`terraform.tfvars` was already updated in step 5.3 to load this file via
`factories_config.paths.cicd_workflows`.

### 11.4 Apply the changes

```bash
terraform apply -var-file=../../../../config/0-org-setup/terraform.tfvars
```

This creates the Workload Identity pool and provider, and generates a
GitHub Actions workflow at `~/fast-config/dpslab/workflows/org-setup.yaml`.

### 11.5 Adapt the generated workflow

The generated workflow assumes Terraform lives at your repo's root and pulls
modules from a private SSH-keyed mirror — neither is true here (`config/`
holds only YAML, and Fabric is public). Save the generated file for
reference, then write an adapted version:

```bash
mkdir -p ~/gcp_landing_zone/docs/generated
cp ~/fast-config/dpslab/workflows/org-setup.yaml \
   ~/gcp_landing_zone/docs/generated/org-setup.generated.yaml

mkdir -p ~/gcp_landing_zone/.github/workflows
```

Key differences in `.github/workflows/org-setup.yml`:

| Generated | Adapted | Why |
|---|---|---|
| Terraform runs at repo root | Runs in `fabric/fast/stages/0-org-setup` | this repo holds `config/`, not stage code |
| SSH-clones a private modules repo (`secrets.CICD_MODULES_KEY`) | `git clone` Fabric at `v57.0.0` from public GitHub | no private mirror exists |
| Copies `0-org-setup.auto.tfvars` | Step removed | stage 0 *emits* that file for other stages; it doesn't consume it itself |

The core of the adapted workflow — authenticate, then plan or apply
depending on whether the PR merged:

```yaml
env:
  FAST_SERVICE_ACCOUNT: iac-org-cicd-rw@dpslab-prod-iac-core-0.iam.gserviceaccount.com
  FAST_SERVICE_ACCOUNT_PLAN: iac-org-cicd-ro@dpslab-prod-iac-core-0.iam.gserviceaccount.com
  FAST_WIF_PROVIDER: projects/273934713254/locations/global/workloadIdentityPools/default/providers/github-default
  FABRIC_REPO: https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git
  FABRIC_VERSION: v57.0.0
  STAGE_DIR: fabric/fast/stages/0-org-setup

steps:
  - uses: actions/checkout@v4

  - name: Clone Fabric at pinned tag
    run: git clone --quiet --depth 1 --branch "${FABRIC_VERSION}" "${FABRIC_REPO}" fabric

  # merged PR -> read-write identity + apply; open/updated PR -> read-only + plan only
  - name: Select identity
    run: |
      if [ "${{ github.event.pull_request.merged }}" = "true" ]; then
        echo "service_account=${{ env.FAST_SERVICE_ACCOUNT }}" >> "$GITHUB_ENV"
      else
        echo "service_account=${{ env.FAST_SERVICE_ACCOUNT_PLAN }}" >> "$GITHUB_ENV"
      fi

  - uses: google-github-actions/auth@v2
    with:
      workload_identity_provider: ${{ env.FAST_WIF_PROVIDER }}
      service_account: ${{ env.service_account }}
```

(See `.github/workflows/org-setup.yml` in the repo for the complete file,
including posting the plan back as a PR comment.)

### 11.6 Commit and push

```bash
git add -A
git commit -m "Wire up CI/CD via Workload Identity Federation"
git remote add origin https://github.com/BilalNagina/gcp_landing_zone.git
git branch -M main
git push -u origin main
```

If the push is rejected with *"refusing to allow a Personal Access Token to
create or update workflow ... without workflow scope"*, your `gh` token is
missing the `workflow` scope — go back to `gh auth refresh -h github.com -s
workflow` in section 3.

---

## 12. Verify the pipeline end to end

Don't trust it until you've watched it actually authenticate. Open a real
pull request against a trivial change:

```bash
git checkout -b test/cicd-check
echo "# trigger CI" >> config/0-org-setup/dataset/organization/tags/environment.yaml
git add -A && git commit -m "Test: verify CI/CD Workload Identity Federation"
git push -u origin test/cicd-check
gh pr create --title "Test CI/CD" --body "Verifying WIF." --base main --head test/cicd-check
```

Watch it run:

```bash
gh run list -R BilalNagina/gcp_landing_zone --limit 1
gh run watch <run-id> -R BilalNagina/gcp_landing_zone
```

A successful run authenticates as the read-only service account, runs
`terraform init` / `validate` / `plan`, and posts the plan as a comment on
the PR — proof that GitHub's token was accepted by Google's IAM with zero
keys anywhere. Once confirmed, close the test PR without merging and delete
the throwaway branch:

```bash
gh pr close <pr-number> --delete-branch
git checkout main
git branch -D test/cicd-check
```

---

## What changed, by directory

| Directory | Origin | What's in it | Do you edit it? |
|---|---|---|---|
| `fabric/` | `git clone` of Google's repo, pinned `v57.0.0` | Generic Terraform stage code | **Never** |
| `config/0-org-setup/dataset/` | Copied from `fabric/.../datasets/classic/` | Your organization's desired state, as YAML | **Yes — this is the whole point** |
| `config/0-org-setup/terraform.tfvars` | Written by hand | Points the stage at your dataset; org-policy import list | Yes, rarely |
| `.github/workflows/` | Adapted from FAST's generated output | The CI/CD pipeline | Yes, when the pipeline itself needs to change |
| `docs/generated/` | Copied from FAST's output, untouched | Reference copy, for diffing against future FAST releases | No |
| `~/fast-config/dpslab/` (outside the repo) | Generated by every `apply` | Provider files and tfvars for downstream stages | Never — always regenerated |

Files actually edited inside `config/0-org-setup/dataset/`, and why:

- **`defaults.yaml`** — org ID, billing account, prefix, region, admin group. The one file every build must customize.
- **`terraform.tfvars`** — dataset path, `cicd_workflows` path, org-policy imports.
- **`cicd.yaml`** — repository name and branch.
- **`projects/core/iac-0.yaml`** — Workload Identity pool and provider.

Nothing under `folders/`, `organization/org-policies/`, or
`organization/custom-roles/` needed editing for this build — the shipped
`classic` defaults were used as-is.

---

## Reference: identifiers used in this build

| Value | This build |
|---|---|
| Organization domain | `bilalnagina.com` |
| Organization ID | `287552611155` |
| Directory customer ID | `C00l7b6x7` |
| Admin user | `lab@bilalnagina.com` |
| Admin group | `gcp-organization-admins@bilalnagina.com` |
| Billing account | `01C191-EEC543-6C1024` |
| Prefix | `dpslab` |
| Region | `me-central1` |
| Automation project | `dpslab-prod-iac-core-0` |
| State bucket | `gs://dpslab-prod-iac-core-0-iac-org-state` |
| GitHub repository | `BilalNagina/gcp_landing_zone` |
| Fabric version | `v57.0.0` |
| Total resources managed | 314 |

---

## Day 2: making a change

Once this is built, you never run `terraform apply` from your laptop again.

1. Create a branch, edit a YAML file under `config/0-org-setup/dataset/`.
2. Open a pull request. The pipeline runs `terraform plan` as the read-only
   identity and posts the diff as a comment.
3. Read the plan. It's a real, resource-level list of what will change in
   your organization — review it like you would review code.
4. Merge to `main`. The pipeline re-runs, this time as the read-write
   identity, and applies.

---

## Troubleshooting quick reference

**`http2: client connection lost` during `plan`/`apply` on WSL2** — a known
WSL2 networking quirk under sustained concurrent connections, not a real
outage (verified: the same requests succeed one at a time). Retry with
`-parallelism=1`. If the failed run also failed to release its state lock,
clear it before retrying:

```bash
gcloud storage objects describe gs://<prefix>-prod-iac-core-0-iac-org-state/default.tflock
# a generation number = locked; a 404 means clear
terraform force-unlock -force <LOCK_ID>   # only if genuinely stranded
```

**`invalid_grant` / `reauth related error (invalid_rapt)`** — your gcloud
user session expired (happens every 1–2 days). Looks similar to the network
issue (many errors at once) but is unrelated — re-run:

```bash
gcloud auth login lab@bilalnagina.com
gcloud auth application-default login
```

**Push rejected: "refusing to allow a Personal Access Token to ... update
workflow ... without workflow scope"** — `gh auth refresh -h github.com -s
workflow`.

**Branch protection unavailable on `main`** — GitHub's free tier doesn't
offer branch protection on private repositories; it requires GitHub Pro (or
a paid org plan). Not fixable from the CLI — either upgrade, make the repo
public, or accept the gap for a solo sandbox.
