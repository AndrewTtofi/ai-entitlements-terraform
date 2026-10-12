# The trust policies, against a mock AWS. What matters is who may assume each role and
# what each role may then do.

mock_provider "aws" {}

variables {
  repository      = "acme/ai-entitlements"
  state_bucket    = "acme-tfstate"
  okta_secret_arn = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:okta-terraform-key"
}

run "each_role_trusts_exactly_one_kind_of_job" {
  command = apply

  assert {
    condition     = jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:acme/ai-entitlements:pull_request"
    error_message = "Plan: pull requests in this repository."
  }
  assert {
    condition     = jsondecode(aws_iam_role.apply.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:acme/ai-entitlements:environment:production"
    error_message = "Apply: only the protected environment."
  }
  assert {
    condition     = alltrue([for role in [aws_iam_role.plan, aws_iam_role.apply] : jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"])
    error_message = "Only tokens minted for AWS STS."
  }
  assert {
    condition     = alltrue([for role in [aws_iam_role.plan, aws_iam_role.apply] : jsondecode(role.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" && length(jsondecode(role.assume_role_policy).Statement) == 1])
    error_message = "One statement, one way in."
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1 && aws_iam_openid_connect_provider.github[0].client_id_list == toset(["sts.amazonaws.com"])
    error_message = "The provider accepts tokens minted for AWS STS only."
  }
  assert {
    condition     = aws_iam_role.plan.max_session_duration == 3600 && aws_iam_role.apply.max_session_duration == 3600
    error_message = "Sessions last an hour."
  }
}

run "a_plan_reads_and_only_an_apply_writes" {
  command = apply

  assert {
    condition     = !strcontains(aws_iam_role_policy.plan.policy, "s3:PutObject") && !strcontains(aws_iam_role_policy.plan.policy, "s3:DeleteObject")
    error_message = "A pull request must not be able to change the state."
  }
  assert {
    condition     = strcontains(aws_iam_role_policy.apply.policy, "s3:PutObject")
    error_message = "An apply writes the state."
  }
  assert {
    condition     = alltrue([for policy in [aws_iam_role_policy.plan.policy, aws_iam_role_policy.apply.policy] : !strcontains(policy, "\"*\"")])
    error_message = "No wildcard actions or resources."
  }
  assert {
    condition     = strcontains(aws_iam_role_policy.plan.policy, "arn:aws:secretsmanager:eu-west-1:111111111111:secret:okta-terraform-key")
    error_message = "The Okta key is read from one named secret."
  }
}

run "an_account_that_already_has_the_provider_reuses_it" {
  command = apply
  variables {
    create_oidc_provider = false
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "An account has one GitHub provider; don't create a second."
  }
}

run "a_wildcard_repository_is_refused" {
  command = plan
  variables {
    repository = "acme/*"
  }
  expect_failures = [var.repository]
}

run "a_repository_without_an_owner_is_refused" {
  command = plan
  variables {
    repository = "ai-entitlements"
  }
  expect_failures = [var.repository]
}
