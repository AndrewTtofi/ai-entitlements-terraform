# 0001 — Entitlements as data, applied by Terraform, with keyless CI

- **Status:** accepted
- **Date:** 2026-10-13

## Context
Who may use which AI tool is decided in the identity provider: which groups exist, who is
in them, which apps they are assigned and what tokens they get. Done by hand in an admin
console, those decisions have no review, no history and no way back, and the answer to
"why does this person have access?" is whoever clicked.

The AI gateway reads the same group names from its policy file to give each group a role.
If the two disagree, a group has a role nobody can hold, or people hold a group that
means nothing.

## Options considered
1. **The admin console** — immediate, and unreviewable.
2. **Scripts against the Okta API** — repeatable, but no plan, no drift detection, and a
   long-lived admin token in whatever runs them.
3. **Terraform resources written out by hand** — reviewable, but the reviewer reads HCL,
   and adding a team means copying four resources.
4. **A small data file, a module that turns it into resources, and a pipeline** where
   the plan is posted on the pull request and nothing holds a static cloud key.

## Decision
Option 4.

**Entitlements are data.** `entitlements/entitlements.yaml` says what each tier grants
(scopes and apps) and, per team, its tier and where its members come from. Adding a team
is a few lines; the reviewer reads a table of who gets what, and the plan underneath it.

**Members come from HR data, by rule.** A team's group is filled by an Okta group rule on
profile attributes (`user.department == "Trading"`). Joiners, movers and leavers then
need no ticket: the profile changes and the group follows.

**Privileged groups are the exception: named people, never a rule.** The group that
approves spend exceptions is a list of at least two logins, and Terraform tracks its
whole membership, so someone added in the console shows up in the next plan as a
removal. A change to somebody's department must not be able to make them an approver.

**Tokens carry only the tier's scopes.** A custom authorization server issues tokens for
the gateway's audience only. One policy rule per tier lists that tier's groups and
scopes; someone in no group matches no rule and gets no token. Clients are public, with
PKCE. Tokens are short (ten minutes), because what someone may do is read from the
gateway's directory on each request, not from the token.

**The same mistakes are refused twice.** A Python validator checks the file in seconds
and in plain words; the module's variable validations refuse the same things for anyone
calling it another way. The validator also checks the file against the gateway's policy:
every group the gateway maps must be created here, every team here must be mapped there,
and a group that approves spend there must be privileged here.

**The modules are tested with mock providers.** `terraform test` plans and applies
against a mock Okta, AWS and Google: no tenant, no account, no credentials in CI. The
assertions are about who is in what, by which mechanism, with which scopes, and about
what must be refused.

**CI holds no static key.**
- GitHub Actions asks GitHub for an OIDC token; AWS trades it for a role.
- Two roles: `plan` (any pull request in this repository; reads the state and the Okta
  key, writes nothing) and `apply` (only jobs in the protected `production`
  environment; may write the state). Each trust policy matches an exact `sub`, never a
  wildcard on the repository.
- Terraform reaches Okta as a service app with a private key and four scopes, not an
  admin's API token. The key lives in AWS Secrets Manager and is read with the
  federated role.
- A module for the same federation into Google Cloud is included.

## Consequences
- An access change is a pull request: a diff, a table, a plan, an approval, an apply,
  and a commit to go back to.
- Console changes to managed objects are drift, and the next plan shows them.
- The data file and the gateway's policy are kept in step by a check, not by a shared
  source. One file feeding both would be better still.
- The rule expressions depend on HR attributes being right. Wrong data in, wrong group
  out, automatically.
- **Nothing here has been applied to a real Okta organisation, AWS account or Google
  project.** Mock providers check the configuration's logic and shape, not Okta's
  behaviour: an attribute Okta rejects at apply time would only be found there.
