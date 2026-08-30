# FAST 0-org-setup - DPS practice sandbox
#
# Run from inside fabric/fast/stages/0-org-setup with:
#   terraform apply -var-file=../../../../config/0-org-setup/terraform.tfvars
#
# The dataset path is relative to the stage directory, not to this file.

factories_config = {
  dataset = "../../../../config/0-org-setup/dataset"
  paths = {
    # Without this, cicd.yaml is ignored and no pipeline is generated.
    # Path is relative to the dataset directory above.
    cicd_workflows = "cicd.yaml"
  }
}

# Google applies a set of "secure by default" org policies to newly created
# organizations. Four of them collide with constraints FAST's classic dataset
# also manages, so they must be imported into state or the first apply fails
# with "already exists".
#
# Verified against org 287552611155 (bilalnagina.com) on 2026-08-26 via:
#   gcloud org-policies list --organization 287552611155
# Now EMPTY. The four policies above were imported and then removed by the
# teardown on 2026-08-26, so there is nothing left to import and FAST will
# simply create them. Re-populating this list would fail with
# "Cannot import non-existent remote object".
#
# On a genuinely fresh org that has never had FAST applied, these four DO exist
# as Google secure-by-default policies and MUST be listed here:
#   iam.allowedPolicyMemberDomains
#   iam.automaticIamGrantsForDefaultServiceAccounts
#   iam.disableServiceAccountKeyUpload
#   storage.uniformBucketLevelAccess
# Always check first:  gcloud org-policies list --organization <ORG_ID>
org_policies_imports = []

# Also pre-existing, but on the newer ".managed." constraints which FAST does
# not manage. Left alone deliberately - they coexist with FAST's equivalents:
#   essentialcontacts.managed.allowedContactDomains
#   iam.managed.disableServiceAccountKeyCreation
#   compute.managed.restrictProtocolForwardingCreationForTypes
