variable "tiers" {
  description = "What each tier grants: scopes on the gateway's tokens and assigned apps."
  type = map(object({
    rank        = number # higher is more: someone in two tiers gets the higher one
    description = string
    scopes      = list(string)
    apps        = list(string)
  }))

  validation {
    condition     = length(distinct([for t in values(var.tiers) : t.rank])) == length(var.tiers)
    error_message = "Each tier needs its own rank."
  }

  validation {
    condition     = alltrue(flatten([for t in values(var.tiers) : [for app in t.apps : contains(keys(var.apps), app)]]))
    error_message = "A tier assigns an app that is not defined."
  }
}

variable "apps" {
  description = "OAuth clients people sign in through. Public clients with PKCE."
  type = map(object({
    label         = string
    redirect_uris = list(string)
  }))

  validation {
    condition = alltrue([
      for app in values(var.apps) : alltrue([
        for uri in app.redirect_uris : can(regex("^(https://|http://(localhost|127\\.0\\.0\\.1)(:[0-9]+)?/)", uri))
      ])
    ])
    error_message = "Redirect URIs must be https, or http on localhost (a native client's loopback)."
  }
}

variable "teams" {
  description = "One group per team: its tier, and where its members come from."
  type = map(object({
    tier        = string
    description = string
    rule        = optional(string)           # an Okta expression on the user's profile
    members     = optional(list(string), []) # logins, for groups without a rule
    privileged  = optional(bool, false)
  }))

  validation {
    condition     = alltrue([for name in keys(var.teams) : can(regex("^[a-z][a-z0-9-]{1,62}$", name))])
    error_message = "Team names are lower-case letters, digits and hyphens."
  }

  validation {
    condition     = alltrue([for t in values(var.teams) : contains(keys(var.tiers), t.tier)])
    error_message = "A team names a tier that is not defined."
  }

  # A privileged group is never filled by a rule: a change to someone's department in
  # the HR system must not be able to make them an approver.
  validation {
    condition     = alltrue([for t in values(var.teams) : !(t.privileged && t.rule != null)])
    error_message = "A privileged team lists its members; it cannot have a rule."
  }

  # Two people, so nobody is the only approver (and nobody approves their own request).
  validation {
    condition     = alltrue([for t in values(var.teams) : !t.privileged || length(t.members) >= 2])
    error_message = "A privileged team needs at least two named members."
  }

  validation {
    condition     = alltrue([for t in values(var.teams) : t.rule != null || length(t.members) > 0])
    error_message = "Every team needs a rule or a list of members."
  }

  validation {
    condition     = alltrue([for t in values(var.teams) : !(t.rule != null && length(t.members) > 0)])
    error_message = "A team has a rule or a list of members, not both: one source of truth per group."
  }
}

variable "gateway_audience" {
  description = "The audience of tokens for the AI gateway (its OIDC_AUDIENCE)."
  type        = string
  default     = "api://ai-gateway"
}

variable "access_token_minutes" {
  description = "How long an access token lives. Short, because entitlements are read from the directory, not the token."
  type        = number
  default     = 10

  validation {
    condition     = var.access_token_minutes >= 5 && var.access_token_minutes <= 60
    error_message = "Between 5 and 60 minutes."
  }
}

variable "scim_app_id" {
  description = "The Okta app that provisions to the gateway over SCIM. When set, every team group is pushed to it."
  type        = string
  default     = null
}
