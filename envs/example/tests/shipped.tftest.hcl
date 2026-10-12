# The shipped data file through the real root, against a mock Okta: what a reviewer
# would see in a plan, without a tenant.

mock_provider "okta" {}

variables {
  okta_org_name    = "dev-123456"
  okta_client_id   = "0oa1exampleCLIENTid"
  okta_private_key = "not-a-key"
}

run "the_shipped_entitlements_plan_cleanly" {
  command = apply

  assert {
    condition     = keys(output.summary) == ["compliance", "eng-backend", "eng-platform", "everyone", "platform-admin", "trading-desk"]
    error_message = "One entry per team in entitlements.yaml."
  }
  assert {
    condition     = output.summary["everyone"].tier == "dev" && output.summary["everyone"].apps == tolist(["ai-cli"])
    error_message = "Everyone gets the dev tier: the CLI and no tools."
  }
  assert {
    condition     = output.summary["platform-admin"].privileged && output.summary["platform-admin"].membership == "named: 2 people"
    error_message = "The approver group is two named people, not a rule."
  }
  assert {
    condition     = output.gateway.OIDC_AUDIENCE == "api://ai-gateway"
    error_message = "The gateway's audience."
  }
}
