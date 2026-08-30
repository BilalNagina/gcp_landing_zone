# FAST practice sandbox — setup runbook

Practice run of Fabric FAST `0-org-setup`, pinned to **v57.0.0**.

> **Do not run any of this against `dpskw.com`.** Your gcloud is currently
> authenticated as `digital.services@dpskw.com`, which can see two live DPS
> billing accounts and eight real projects. Stage 0 applies org-wide policies
> and IAM. This runbook builds a **separate throwaway organization**.

---

## Platform requirement: Linux or WSL2 — not Windows

**FAST cannot be run from Windows.** This is not a preference. Confirmed
empirically on 2026-08-26 against Fabric v57.0.0:

```
> fileset(...)                                    "security/dev/.config.yaml"   ok
> dirname("security/dev/.config.yaml")            "security\\dev"               <-- backslash
> length(split("/", dirname(...)))                1                             <-- should be 2
```

Terraform's `dirname()` is OS-dependent and emits Windows separators. FAST's
YAML factories derive resource nesting by splitting that key on `/`, so on
Windows **every nested folder collapses to the top level**.

Affected, all in `modules/`:

| File | Uses `dirname()` for | Consequence on Windows |
|---|---|---|
| `project-factory/folders.tf` | folder nesting, `parent_key` | flat folder hierarchy |
| `project-factory/projects.tf` | `parent = "$folder_ids:${dirname(f)}"` | projects land in wrong parent |
| `net-vpc-factory/main.tf` | VPC factory paths | breaks `2-networking` |

The dangerous part is that **it does not fail loudly**. Stage 0 reports success
and produces a folder tree that looks plausible until you list the hierarchy and
compare it against intent. The first run of this sandbox produced five flat
folders under the org where two should have been nested.

Run everything from WSL2 or a Linux host. Do not work off `/mnt/c` either —
clone into the Linux home directory.

---

## Repo layout

```
gcp_landing_zone/
├── fabric/                     # upstream, pinned to v57.0.0 — never edit
│   └── fast/stages/0-org-setup/
├── config/0-org-setup/
│   ├── dataset/                # our copy of datasets/classic — edit this
│   │   └── defaults.yaml       # <- the file with the TODOs
│   └── terraform.tfvars        # points the stage at our dataset
└── SANDBOX-SETUP.md
```

To re-create `fabric/` from scratch:

```
git clone --depth 1 --branch v57.0.0 \
  https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git fabric
```

---

## Part A — things only you can do in a browser

### A1. Domain — use `lab.bilalnagina.com`

Already owned: `bilalnagina.com`, registered at GoDaddy, on GoDaddy nameservers
(`ns73/ns74.domaincontrol.com`). No new purchase needed.

**Sign up with the subdomain `lab.bilalnagina.com`, not the apex.** Cloud
Identity accepts a subdomain as its primary domain, and this keeps the sandbox
isolated from your real domain.

The apex already has live records — leave all of them alone:

| Record | Value |
|---|---|
| MX | `smtp.secureserver.net` (0), `mailstore1.secureserver.net` (10) — GoDaddy email |
| TXT | `v=spf1 include:secureserver.net -all` |
| A | `216.198.79.1` |

Why the subdomain: once Cloud Identity owns a domain, any existing personal
Google account using an address at that domain becomes a **conflicting account**
and is forced through a rename/migration. GoDaddy email is already running on
the apex, so that risk is real. A subdomain avoids it entirely and can be torn
down later without touching `bilalnagina.com`.

**Never use `dpskw.com`.**

### A2. Sign up for Cloud Identity Free

<https://workspace.google.com/gcpidentity/signup?sku=identitybasic>

- Free edition, up to 50 users, no card required.
- Use the domain from A1.
- The admin user you create here (e.g. `admin@dps-fast-lab.com`) becomes
  **super admin** and is the identity you will run Terraform as.
- Signing up **auto-creates a GCP organization** for the domain. That org node
  is the whole reason for this exercise.

### A3. Verify the domain (GoDaddy)

Google's wizard gives you a `google-site-verification=...` string. Add it as a
**TXT record** — this is the only DNS change the whole exercise requires.
Cloud Identity Free has no Gmail, so **no MX changes are ever needed** and your
GoDaddy email is unaffected.

GoDaddy → **My Products** → **Domains** → `bilalnagina.com` → **DNS** →
**Manage DNS** → **Add New Record**:

| Field | Value |
|---|---|
| Type | `TXT` |
| Name | `lab`  (just `lab`, not the full subdomain) |
| Value | `google-site-verification=...` from Google |
| TTL | 1 hour |

Save, then click **Verify** in the Google wizard. Usually a few minutes.

Do not modify the existing MX, SPF, or A records — the new TXT sits alongside
them. Check it has propagated with:

```
Resolve-DnsName -Name lab.bilalnagina.com -Type TXT -Server 8.8.8.8
```

### A4. Create the admin group

In the Admin console (<https://admin.google.com>) → Directory → Groups:

- Create `gcp-organization-admins@<your-domain>`
- **Add your admin user as a member.** FAST binds org IAM to this group, not to
  your user. If the group is empty or you are not in it, the first apply hands
  all org control to a group with no members and locks you out.

### A5. Create a billing account

<https://console.cloud.google.com/billing> → Create account, signed in as the
new admin user. Take the $300 / 90-day free trial if offered.

**Do not link the DPS "Main Billing Account".**

---

## Part B — collect the five values

Sign in with the new admin user, then:

```
gcloud auth login admin@<your-domain>
gcloud config set account admin@<your-domain>

# org id + customer id
gcloud organizations list \
  --format="table(displayName, ID, owner.directoryCustomerId)"

# billing account id
gcloud beta billing accounts list
```

Put the results into `config/0-org-setup/dataset/defaults.yaml`, replacing every
`TODO-` marker:

| Field | Source |
|---|---|
| `global.billing_account` | `gcloud beta billing accounts list` |
| `global.organization.domain` | your sandbox domain |
| `global.organization.id` | `gcloud organizations list` → ID |
| `global.organization.customer_id` | `gcloud organizations list` → directoryCustomerId |
| `context.*.gcp-organization-admins` | the group from A4 |

Already set for you: `prefix: dpslab`, `locations.primary: me-central1`.

---

## Part C — grant yourself the bootstrap roles

```
export FAST_ORG_ID=<org-id>
export FAST_PRINCIPAL="group:gcp-organization-admins@<your-domain>"

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
  gcloud organizations add-iam-policy-binding $FAST_ORG_ID \
    --member "$FAST_PRINCIPAL" --role $role --condition None
done
```

PowerShell equivalent:

```
$org = "<org-id>"
$principal = "group:gcp-organization-admins@<your-domain>"
@("roles/billing.admin","roles/logging.admin","roles/iam.organizationRoleAdmin",
  "roles/orgpolicy.policyAdmin","roles/resourcemanager.folderAdmin",
  "roles/resourcemanager.organizationAdmin","roles/resourcemanager.projectCreator",
  "roles/resourcemanager.tagAdmin","roles/owner") | ForEach-Object {
  gcloud organizations add-iam-policy-binding $org --member $principal --role $_ --condition None
}
```

Also link your billing account to the org and grant `roles/billing.admin` on it.

---

## Part D — bootstrap project and APIs

Stage 0 needs somewhere to run its first apply from.

```
gcloud projects create <prefix>-bootstrap --organization=<org-id>
gcloud billing projects link <prefix>-bootstrap --billing-account=<billing-id>
gcloud config set project <prefix>-bootstrap

gcloud services enable \
  bigquery.googleapis.com cloudbilling.googleapis.com \
  cloudresourcemanager.googleapis.com essentialcontacts.googleapis.com \
  iam.googleapis.com logging.googleapis.com orgpolicy.googleapis.com \
  serviceusage.googleapis.com
```

Check for colliding org policies (usually none on a fresh org):

```
gcloud org-policies list --organization <org-id>
```

Anything listed must be added to `org_policies_imports` in
`config/0-org-setup/terraform.tfvars`, or the first apply fails.

---

## Part E — the two applies

All commands run from `fabric/fast/stages/0-org-setup`.

### Apply #1 — user credentials, local state

```
terraform init
terraform apply -var-file=../../../../config/0-org-setup/terraform.tfvars
```

Creates the `iac-0` bootstrap project, automation service accounts, GCS state
buckets, org policies, custom roles, folders, log sinks and billing export.

### Migrate state to GCS

```
# providers file is written to ~/fast-config/dpslab/providers/
cp ~/fast-config/dpslab/providers/0-org-setup-providers.tf ./
terraform init -migrate-state -force-copy
```

### Apply #2 — as the service account

> **Unset `GOOGLE_CLOUD_QUOTA_PROJECT` first.** It is a bootstrap-only crutch:
> your *user* credentials need a project with the APIs enabled, but once
> Terraform impersonates `iac-org-rw` it forces the service account to bill API
> calls against a project it has no rights on. Symptom:
> `UserProjectAccessDenied ... does not have serviceusage.services.use`.
> Every stage will fail the same way at the same point if it stays set.

```
unset GOOGLE_CLOUD_QUOTA_PROJECT
terraform apply -var-file=../../../../config/0-org-setup/terraform.tfvars
```

### Confirm convergence

```
terraform plan -detailed-exitcode -var-file=../../../../config/0-org-setup/terraform.tfvars
# exit 0 = no changes (done)   exit 2 = changes still pending
```

From here nothing runs on your personal org-admin credentials.

**Done when:** state lives in GCS, apply #2 is clean under impersonation, and
`terraform plan` reports no changes.

---

## Cost

Stage 0 itself is effectively free — folders, projects, IAM, org policies,
service accounts and empty buckets carry no charge. Expect cents for log
storage and the BigQuery billing export.

Costs only start at `2-networking`, from Cloud NAT (~$0.044/gateway/hour) and
HA VPN tunnels (~$0.05/tunnel/hour). Destroy those when not in use.

## Teardown

```
terraform destroy -var-file=../../../../config/0-org-setup/terraform.tfvars
```

Destroy runs in reverse dependency order and will not remove the org node
itself. Some org policies and liens may need clearing by hand.

---

## Known gotchas

- **Empty admin group locks you out.** Verify membership before apply #1.
- **`prefix` is effectively permanent.** It is stamped into every project ID.
  `dpslab` is set; change it now or not at all.
- **`me-central1`** is set to mirror a real Kuwait engagement. If an apply fails
  on service availability, fall back to `europe-west1` — but change it *before*
  the first apply.
- **Project quota** on a brand-new org is low and stage 0 creates several
  projects. If you hit the cap, request an increase in the Console.
- **OneDrive.** This tree syncs to OneDrive. `.terraform/` holds ~1 GB of
  providers and `*.tfstate` may contain secrets — both are gitignored, but
  consider excluding the folder from OneDrive sync too.
