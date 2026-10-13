# Runbook

How to change who gets what, how to set the pipeline up, and what to do when it
disagrees with reality.

## Change an entitlement

Every change is the same five steps:

1. Edit `entitlements/entitlements.yaml` on a branch.
2. `make check` (seconds; no credentials needed), or `docker compose up --build` for the
   same checks without Terraform or Python installed.
3. Open a pull request. CI validates the file; the `plan` workflow comments with the
   table of who gets what and the Terraform plan.
4. A reviewer approves **the plan**, not only the diff.
5. Merge. The `apply` workflow waits for the `production` environment's reviewers, then
   applies.

| I want to… | Change |
|------------|--------|
| Add a team | A new entry under `teams:` with a `tier`, a `description` and a `rule` |
| Change who is in a team | Its `rule` (or, for a privileged team, its `members`) |
| Give a team more | Its `tier`, or what the tier grants under `tiers:` |
| Add an approver | Their login under the privileged team's `members` |
| Add a sign-in client | An entry under `apps:`, and its name under the tiers that get it |
| Take access away at once | Deactivate the user in Okta. That is not a Terraform change, and it should not wait for a pull request |

If the AI gateway is in use, change its `config/policy.yaml` in step with this file, and
check them against each other: `python -m tools.validate --gateway-policy <path>`.

## Set the pipeline up (once)

Nothing below has been done for this repository; the workflows skip themselves until the
variables exist.

1. **Okta:** create an API service app (Applications → Create App Integration → API
   Services) with a public key, and grant it `okta.groups.manage`, `okta.apps.manage`,
   `okta.authorizationServers.manage` and `okta.users.read`. Give it an admin role scoped
   to groups and apps.
2. **AWS:** store the app's private key in Secrets Manager. Create an S3 bucket for the
   state (versioned, encrypted, private).
3. **Federation:** apply `modules/github-oidc-aws` once, by hand, with your repository,
   bucket and secret ARN. It outputs the two role ARNs.
4. **GitHub:** create the `production` environment with required reviewers, and set the
   repository variables:

| Variable | Value |
|----------|-------|
| `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN` | From step 3 |
| `AWS_REGION`, `TF_STATE_BUCKET` | Where the state is |
| `OKTA_SECRET_ARN` | The secret from step 2 |
| `OKTA_ORG_NAME`, `OKTA_CLIENT_ID` | The organisation and the service app |
| `OKTA_SCIM_APP_ID` | Optional: the app that provisions to the gateway |

They are variables, not secrets: none of them is a credential. The only secret is the
Okta key, and it never leaves AWS except into a running job.

For Google Cloud instead of AWS, `modules/github-oidc-gcp` creates the workload identity
pool, provider and service account; the workflows would use
`google-github-actions/auth` in place of the AWS step.

## When something is wrong

### The plan shows a change nobody made
Someone changed a managed object in the Okta console. Decide which is right: apply to put
it back, or change the data file to match and say why in the pull request.

### The plan wants to remove someone from the approver group
They were added in the console. That is the design: Terraform is the only source of that
group's members. Add their login to `members` in a pull request if they should be there.

### `Error: could not assume role` in the plan workflow
The trust policy matches the token's `sub` exactly. Check:
- the repository is the one the role was created for (a fork or a rename changes `sub`);
- the plan runs on a `pull_request` event, and the apply in the `production` environment;
- the account's GitHub OIDC provider exists.

A pull request from a fork gets no OIDC token at all. That is intended.

### `Error: … invalid_client` or `invalid_scope` from Okta
The service app's key was rotated without updating the secret, or the app lacks one of
the four scopes.

### A user is in the right group but gets no token
Look at the authorization server's policy rules in the plan: the user's group must be in
the `group_whitelist` of a rule, and the app they sign in through must be in the
policy's `client_whitelist`. Both come from the data file: the team's tier, and the apps
that tier assigns.

### A user has a token but the gateway refuses them
The gateway reads groups from its own directory, filled over SCIM. Check that
`OKTA_SCIM_APP_ID` is set (so groups are pushed), and that the gateway's policy maps the
group to a role: `python -m tools.validate --gateway-policy <path>`.

### A rule put the wrong people in a group
The rule did what the profile data said. Fix the data in the HR source, or the rule here.
To empty the group immediately, deactivate the rule in Okta, then fix it in a pull request.

### Roll back
Revert the merge commit. The plan on the revert's pull request shows the access being
put back; merge it.

## What Terraform manages, and what it doesn't

| Managed here | Not managed here |
|--------------|------------------|
| Team groups and their rules | Users and their profile attributes (HR source) |
| Membership of privileged groups | Membership of ruled groups (the rule decides) |
| Sign-in clients and their group assignments | The SCIM app's own provisioning settings |
| The gateway's authorization server, scopes and token policy | What a role may do (the gateway's policy file) |
| Group push to the SCIM app | Deactivating a user |
