output "groups" {
  description = "Team → Okta group id."
  value       = { for name, group in okta_group.team : name => group.id }
}

output "issuer" {
  description = "The gateway's OIDC_ISSUER."
  value       = okta_auth_server.gateway.issuer
}

output "audience" {
  description = "The gateway's OIDC_AUDIENCE."
  value       = var.gateway_audience
}

output "client_ids" {
  description = "App → OAuth client id, to configure in each client."
  value       = { for name, app in okta_app_oauth.app : name => app.client_id }
}

output "summary" {
  description = "Who gets what, for the plan output and for reviewers."
  value = {
    for name, team in var.teams : name => {
      tier       = team.tier
      scopes     = var.tiers[team.tier].scopes
      apps       = var.tiers[team.tier].apps
      membership = team.rule != null ? "rule: ${team.rule}" : "named: ${length(team.members)} people"
      privileged = team.privileged
    }
  }
}
