# An example root: the entitlements data file in, Okta out.
#
#   terraform init
#   terraform plan
#
# In CI the plan runs on every pull request and is posted as a comment
# (.github/workflows/plan.yml); the apply runs from the protected environment after merge.

terraform {
  required_version = ">= 1.9"
  required_providers {
    okta = {
      source  = "okta/okta"
      version = "~> 7.0"
    }
  }

  # State in S3, reached with the role GitHub Actions federates into: no stored AWS key.
  # Bucket, key and region come from `-backend-config` in the workflow.
  backend "s3" {}
}

variable "okta_org_name" {
  description = "The Okta organisation, e.g. dev-123456."
  type        = string
}

variable "okta_base_url" {
  description = "okta.com, oktapreview.com or okta-emea.com."
  type        = string
  default     = "okta.com"
}

variable "okta_client_id" {
  description = "The client id of the Okta API service app Terraform runs as."
  type        = string
}

variable "okta_private_key" {
  description = "That app's private key (PEM). In CI it is read from AWS Secrets Manager."
  type        = string
  sensitive   = true
}

variable "scim_app_id" {
  description = "The Okta app that provisions to the AI gateway over SCIM, if there is one."
  type        = string
  default     = null
}

# A service app with a private key and exactly the scopes below, not an admin's API
# token: the token would carry that admin's whole reach and never expire.
provider "okta" {
  org_name    = var.okta_org_name
  base_url    = var.okta_base_url
  client_id   = var.okta_client_id
  private_key = var.okta_private_key
  scopes = [
    "okta.groups.manage",
    "okta.apps.manage",
    "okta.authorizationServers.manage",
    "okta.users.read",
  ]
}

locals {
  entitlements = yamldecode(file("${path.module}/../../entitlements/entitlements.yaml"))
}

module "entitlements" {
  source = "../../modules/entitlements"

  tiers       = local.entitlements.tiers
  apps        = local.entitlements.apps
  teams       = local.entitlements.teams
  scim_app_id = var.scim_app_id
}

output "summary" {
  description = "Who gets what. Reviewers read this in the plan."
  value       = module.entitlements.summary
}

output "gateway" {
  description = "What to set on the AI gateway."
  value = {
    OIDC_ISSUER   = module.entitlements.issuer
    OIDC_AUDIENCE = module.entitlements.audience
  }
}

output "client_ids" {
  value = module.entitlements.client_ids
}
