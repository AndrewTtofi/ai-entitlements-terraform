variable "project_id" {
  description = "The Google Cloud project."
  type        = string
}

variable "repository" {
  description = "The GitHub repository allowed to impersonate the service account, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.repository))
    error_message = "owner/name, with no wildcards."
  }
}

variable "environment" {
  description = "The GitHub environment whose jobs may impersonate the service account."
  type        = string
  default     = "production"
}
