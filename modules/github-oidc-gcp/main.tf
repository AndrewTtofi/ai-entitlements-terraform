# GitHub Actions → Google Cloud without a service account key.
#
# A workload identity pool trusts GitHub's OIDC issuer. The provider's condition admits
# tokens from one repository only, and the binding lets jobs from one environment of that
# repository impersonate one service account. No JSON key file exists to leak.

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "Federated identities for GitHub Actions workflows. Managed by Terraform."
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  # Which claims of GitHub's token become attributes Google can match on.
  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.environment" = "assertion.environment"
  }

  # Without a condition the pool would accept a token from any repository on GitHub.
  attribute_condition = "assertion.repository == \"${var.repository}\""
}

resource "google_service_account" "terraform" {
  project      = var.project_id
  account_id   = "ai-entitlements-terraform"
  display_name = "AI entitlements: Terraform from GitHub Actions"
}

# Only jobs in the protected environment of this repository may act as the service account.
resource "google_service_account_iam_member" "github" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.environment/${var.environment}"
}
