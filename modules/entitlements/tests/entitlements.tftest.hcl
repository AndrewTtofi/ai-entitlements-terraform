# The module against a mock Okta: no tenant, no credentials. Ids are generated, so the
# assertions are about shape: who is in what, by which mechanism, with which scopes.

mock_provider "okta" {}

variables {
  tiers = {
    dev      = { rank = 1, description = "Small models", scopes = ["gateway.use"], apps = ["ai-cli"] }
    standard = { rank = 2, description = "All models and tools", scopes = ["gateway.use", "tools.use"], apps = ["ai-cli", "mcp"] }
  }
  apps = {
    ai-cli = { label = "AI CLI", redirect_uris = ["http://localhost:8765/callback"] }
    mcp    = { label = "MCP", redirect_uris = ["https://mcp.example.com/callback"] }
  }
  teams = {
    eng            = { tier = "standard", description = "Engineering", rule = "user.department == \"Engineering\"" }
    everyone       = { tier = "dev", description = "Everyone", rule = "user.userType == \"Employee\"" }
    platform-admin = { tier = "standard", description = "Approvers", privileged = true, members = ["alice@example.com", "bob@example.com"] }
  }
}

run "groups_and_how_they_are_filled" {
  command = apply

  assert {
    condition     = length(okta_group.team) == 3
    error_message = "One group per team."
  }
  assert {
    condition     = keys(okta_group_rule.team) == ["eng", "everyone"]
    error_message = "Teams with a rule get a group rule."
  }
  assert {
    condition     = okta_group_rule.team["eng"].expression_value == "user.department == \"Engineering\""
    error_message = "The rule is the expression from the data."
  }
  assert {
    condition     = keys(okta_group_memberships.team) == ["platform-admin"]
    error_message = "Only the team with named members has managed memberships."
  }
  assert {
    condition     = length(okta_group_memberships.team["platform-admin"].users) == 2
    error_message = "Both named members."
  }
  assert {
    condition     = okta_group_memberships.team["platform-admin"].track_all_users
    error_message = "Terraform is the only source of membership for a privileged group."
  }
}

run "apps_are_public_clients_assigned_by_tier" {
  command = apply

  assert {
    condition     = alltrue([for app in okta_app_oauth.app : app.pkce_required && app.token_endpoint_auth_method == "none"])
    error_message = "Clients on a user's machine use PKCE and hold no secret."
  }
  assert {
    condition     = length(okta_app_group_assignments.app["ai-cli"].group) == 3
    error_message = "Every tier assigns the CLI, so every team has it."
  }
  assert {
    condition     = length(okta_app_group_assignments.app["mcp"].group) == 2
    error_message = "Only the standard tier assigns the MCP client."
  }
}

run "tokens_carry_only_the_scopes_of_the_tier" {
  command = apply

  assert {
    condition     = length(okta_auth_server.gateway.audiences) == 1 && contains(okta_auth_server.gateway.audiences, "api://ai-gateway")
    error_message = "Tokens are issued for the gateway and nothing else."
  }
  assert {
    condition     = keys(okta_auth_server_scope.scope) == ["gateway.use", "tools.use"]
    error_message = "The union of the tiers' scopes."
  }
  assert {
    condition     = okta_auth_server_policy_rule.tier["dev"].scope_whitelist == toset(["gateway.use"])
    error_message = "The dev tier does not get tools."
  }
  assert {
    condition     = length(okta_auth_server_policy_rule.tier["dev"].group_whitelist) == 1 && length(okta_auth_server_policy_rule.tier["standard"].group_whitelist) == 2
    error_message = "Each tier's rule lists exactly its teams."
  }
  assert {
    condition     = okta_auth_server_policy_rule.tier["standard"].priority < okta_auth_server_policy_rule.tier["dev"].priority
    error_message = "The higher tier is evaluated first."
  }
  assert {
    condition     = alltrue([for rule in okta_auth_server_policy_rule.tier : rule.grant_type_whitelist == toset(["authorization_code"]) && rule.access_token_lifetime_minutes == 10])
    error_message = "People sign in; tokens are short."
  }
  assert {
    condition     = length(okta_auth_server_policy.gateway.client_whitelist) == 2
    error_message = "Only the apps defined here may ask this server for a token."
  }
}

run "groups_are_pushed_only_when_there_is_a_scim_app" {
  command = apply

  assert {
    condition     = length(okta_push_group.team) == 0
    error_message = "No SCIM app, no push."
  }
}

run "with_a_scim_app_every_team_is_pushed" {
  command = apply
  variables {
    scim_app_id = "0oa1scimAPP"
  }

  assert {
    condition     = length(okta_push_group.team) == 3
    error_message = "Every team group is provisioned to the gateway."
  }
}

run "the_summary_says_who_gets_what" {
  command = apply

  assert {
    condition     = output.summary["everyone"].scopes == tolist(["gateway.use"]) && !output.summary["everyone"].privileged
    error_message = "The summary shows the tier's scopes."
  }
  assert {
    condition     = output.summary["platform-admin"].membership == "named: 2 people"
    error_message = "The summary shows how a group is filled."
  }
}

# --- what must be refused --------------------------------------------------------------

run "a_privileged_team_cannot_be_filled_by_a_rule" {
  command = plan
  variables {
    teams = {
      platform-admin = { tier = "standard", description = "x", privileged = true, rule = "user.department == \"IT\"" }
    }
  }
  expect_failures = [var.teams]
}

run "a_privileged_team_needs_two_people" {
  command = plan
  variables {
    teams = {
      platform-admin = { tier = "standard", description = "x", privileged = true, members = ["alice@example.com"] }
    }
  }
  expect_failures = [var.teams]
}

run "a_team_needs_a_source_of_members" {
  command = plan
  variables {
    teams = { ghosts = { tier = "dev", description = "x" } }
  }
  expect_failures = [var.teams]
}

run "a_team_cannot_have_two_sources_of_members" {
  command = plan
  variables {
    teams = { eng = { tier = "dev", description = "x", rule = "user.department == \"E\"", members = ["a@example.com"] } }
  }
  expect_failures = [var.teams]
}

run "a_redirect_over_plain_http_is_refused_unless_it_is_localhost" {
  command = plan
  variables {
    apps = {
      ai-cli = { label = "AI CLI", redirect_uris = ["http://evil.example/callback"] }
      mcp    = { label = "MCP", redirect_uris = ["https://mcp.example.com/callback"] }
    }
  }
  expect_failures = [var.apps]
}

run "a_team_in_a_tier_that_does_not_exist_is_caught" {
  command = plan
  variables {
    teams = { eng = { tier = "gold", description = "x", rule = "user.department == \"E\"" } }
  }
  expect_failures = [var.teams]
}

run "two_tiers_cannot_share_a_rank" {
  command = plan
  variables {
    tiers = {
      dev      = { rank = 1, description = "a", scopes = ["gateway.use"], apps = ["ai-cli"] }
      standard = { rank = 1, description = "b", scopes = ["gateway.use"], apps = ["ai-cli", "mcp"] }
    }
  }
  expect_failures = [var.tiers]
}

run "a_tier_cannot_assign_an_app_that_does_not_exist" {
  command = plan
  variables {
    tiers = {
      dev      = { rank = 1, description = "a", scopes = ["gateway.use"], apps = ["ai-cli", "ghost"] }
      standard = { rank = 2, description = "b", scopes = ["gateway.use"], apps = ["ai-cli"] }
    }
  }
  expect_failures = [var.tiers]
}
