# Entitlements for AI tools, from data. One group per team, filled by a rule or by named
# people; apps assigned by tier; and an authorization server whose tokens carry only the
# scopes a team's tier grants.

locals {
  ruled  = { for name, team in var.teams : name => team if team.rule != null }
  listed = { for name, team in var.teams : name => team if team.rule == null }
  logins = toset(flatten([for team in values(local.listed) : team.members]))
  scopes = toset(flatten([for tier in values(var.tiers) : tier.scopes]))
  # tier → the teams in it
  by_tier = { for tier in keys(var.tiers) : tier => [for name, team in var.teams : name if team.tier == tier] }
  # app → the teams whose tier assigns it
  by_app = {
    for app in keys(var.apps) : app => [
      for name, team in var.teams : name if contains(var.tiers[team.tier].apps, app)
    ]
  }
}

# --- groups ----------------------------------------------------------------------------

resource "okta_group" "team" {
  for_each    = var.teams
  name        = each.key
  description = "${each.value.description} (AI tier: ${each.value.tier}). Managed by Terraform."
}

# Membership from the user's profile: HR data in, group membership out. A mover changes
# department and changes group; a leaver is deactivated and drops out.
resource "okta_group_rule" "team" {
  for_each          = local.ruled
  name              = "ai-${each.key}"
  status            = "ACTIVE"
  group_assignments = [okta_group.team[each.key].id]
  expression_type   = "urn:okta:expression:1.0"
  expression_value  = each.value.rule
}

data "okta_user" "member" {
  for_each = local.logins
  search {
    name       = "profile.login"
    value      = each.key
    comparison = "eq"
  }
}

# Named people. `track_all_users` makes Terraform the only source of membership: someone
# added by hand in the console shows up in the next plan as a removal.
resource "okta_group_memberships" "team" {
  for_each        = local.listed
  group_id        = okta_group.team[each.key].id
  users           = [for login in each.value.members : data.okta_user.member[login].id]
  track_all_users = true
}

# --- apps ------------------------------------------------------------------------------

resource "okta_app_oauth" "app" {
  for_each                   = var.apps
  label                      = each.value.label
  type                       = "native"
  grant_types                = ["authorization_code", "refresh_token"]
  response_types             = ["code"]
  redirect_uris              = each.value.redirect_uris
  token_endpoint_auth_method = "none" # a public client: it can't keep a secret
  pkce_required              = true
  consent_method             = "REQUIRED"
}

resource "okta_app_group_assignments" "app" {
  for_each = var.apps
  app_id   = okta_app_oauth.app[each.key].id

  dynamic "group" {
    for_each = toset(local.by_app[each.key])
    content {
      id = okta_group.team[group.value].id
    }
  }
}

# --- tokens for the gateway ------------------------------------------------------------

resource "okta_auth_server" "gateway" {
  name        = "ai-gateway"
  description = "Issues access tokens for the AI gateway. Managed by Terraform."
  audiences   = [var.gateway_audience]
  issuer_mode = "ORG_URL"
}

resource "okta_auth_server_scope" "scope" {
  for_each         = local.scopes
  auth_server_id   = okta_auth_server.gateway.id
  name             = each.key
  description      = "AI platform: ${each.key}"
  consent          = "REQUIRED"
  metadata_publish = "ALL_CLIENTS"
}

# Only the apps defined here may get a token from this server.
resource "okta_auth_server_policy" "gateway" {
  auth_server_id   = okta_auth_server.gateway.id
  name             = "ai-entitlements"
  description      = "Tokens for the AI gateway, by tier"
  priority         = 1
  client_whitelist = [for app in okta_app_oauth.app : app.client_id]
}

# One rule per tier: the groups in it, and the scopes it grants. Someone in no group
# matches no rule and gets no token.
resource "okta_auth_server_policy_rule" "tier" {
  for_each       = { for tier, teams in local.by_tier : tier => teams if length(teams) > 0 }
  auth_server_id = okta_auth_server.gateway.id
  policy_id      = okta_auth_server_policy.gateway.id
  name           = "tier-${each.key}"
  # The highest tier is evaluated first, so someone in two tiers gets the larger grant.
  priority                      = 1 + max([for t in values(var.tiers) : t.rank]...) - var.tiers[each.key].rank
  grant_type_whitelist          = ["authorization_code"]
  group_whitelist               = [for team in each.value : okta_group.team[team].id]
  scope_whitelist               = var.tiers[each.key].scopes
  access_token_lifetime_minutes = var.access_token_minutes
}

# --- provisioning to the gateway -------------------------------------------------------

# Pushing a group to the SCIM app is what sends its members to the gateway's directory.
resource "okta_push_group" "team" {
  for_each        = var.scim_app_id == null ? {} : var.teams
  app_id          = var.scim_app_id
  source_group_id = okta_group.team[each.key].id
}
