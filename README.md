# GCP landing zone - practice sandbox

Fabric FAST `0-org-setup` against organization `bilalnagina.com` (287552611155),
pinned to Fabric **v57.0.0**.

This repository holds the **desired state** of the organization. The YAML under
`config/` is the source of truth; Terraform turns it into GCP resources.

## Layout

```
config/0-org-setup/
  dataset/            what the org should look like (edit this)
  terraform.tfvars    points the stage at the dataset
fabric/               upstream Fabric, gitignored - clone separately
SANDBOX-SETUP.md      full runbook, prerequisites and known gotchas
```

## Restore the working tree

```bash
git clone <this-repo> gcp_landing_zone && cd gcp_landing_zone
git clone --depth 1 --branch v57.0.0 \
  https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git fabric
```

## Run a change

```bash
cd fabric/fast/stages/0-org-setup
cp ~/fast-config/dpslab/providers/0-org-setup-providers.tf ./
unset GOOGLE_CLOUD_QUOTA_PROJECT          # breaks impersonation if set
terraform init
terraform plan  -var-file=../../../../config/0-org-setup/terraform.tfvars
terraform apply -var-file=../../../../config/0-org-setup/terraform.tfvars
```

**Must run on Linux or WSL2.** Terraform's `dirname()` returns backslashes on
Windows, which silently flattens the folder hierarchy. See SANDBOX-SETUP.md.
