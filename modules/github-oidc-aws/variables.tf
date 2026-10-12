variable "repository" {
  description = "The GitHub repository allowed to assume these roles, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.repository))
    error_message = "owner/name, with no wildcards: a trust policy that matches any repository trusts everyone on GitHub."
  }
}

variable "apply_environment" {
  description = "The GitHub environment whose jobs may apply. Protect it with required reviewers."
  type        = string
  default     = "production"
}

variable "state_bucket" {
  description = "The S3 bucket holding the Terraform state."
  type        = string
}

variable "okta_secret_arn" {
  description = "The Secrets Manager secret holding the Okta service app's private key."
  type        = string
}

variable "create_oidc_provider" {
  description = "Create the account's GitHub OIDC provider. False if the account already has one."
  type        = bool
  default     = true
}
