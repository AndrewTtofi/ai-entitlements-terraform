# The federation, against a mock Google provider.

mock_provider "google" {
  # The mock invents ids; these two have formats other resources check.
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/acme-platform/serviceAccounts/ai-entitlements-terraform@acme-platform.iam.gserviceaccount.com"
      email = "ai-entitlements-terraform@acme-platform.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_iam_workload_identity_pool" {
    defaults = {
      name = "projects/123456789/locations/global/workloadIdentityPools/github-actions"
    }
  }
}

variables {
  project_id = "acme-platform"
  repository = "acme/ai-entitlements"
}

run "only_this_repository_and_environment_get_in" {
  command = apply

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository == \"acme/ai-entitlements\""
    error_message = "The provider admits one repository."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.github.oidc[0].issuer_uri == "https://token.actions.githubusercontent.com"
    error_message = "GitHub's issuer."
  }
  assert {
    condition     = endswith(google_service_account_iam_member.github.member, "/attribute.environment/production")
    error_message = "Only the protected environment may impersonate the service account."
  }
  assert {
    condition     = google_service_account_iam_member.github.role == "roles/iam.workloadIdentityUser"
    error_message = "Impersonation, and nothing broader."
  }
}

run "a_wildcard_repository_is_refused" {
  command = plan
  variables {
    repository = "acme/*"
  }
  expect_failures = [var.repository]
}
