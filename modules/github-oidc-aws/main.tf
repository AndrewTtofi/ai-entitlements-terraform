# GitHub Actions → AWS without a stored key.
#
# A workflow asks GitHub for a short-lived OIDC token that says which repository, branch
# and environment it runs for. AWS trusts GitHub's issuer, and each role's trust policy
# says exactly which of those claims may assume it. There is no access key to leak,
# rotate or forget in a repository secret.
#
# Two roles, because a plan and an apply are different levels of trust:
#   plan    any pull request in the repository: read the state and the Okta key, change nothing
#   apply   only jobs in the protected environment: read and write the state

locals {
  issuer = "token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.issuer}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://${local.issuer}"
}

locals {
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

locals {
  # `sub` is what GitHub asserts about the job. Exact matches, never a wildcard on the
  # repository: `repo:org/*` would trust every repository in the organisation.
  subjects = {
    plan  = "repo:${var.repository}:pull_request"
    apply = "repo:${var.repository}:environment:${var.apply_environment}"
  }

  # Written with jsonencode rather than a policy-document data source, so the tests can
  # read the real policy and not a mocked one.
  trust = {
    for role, subject in local.subjects : role => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = local.provider_arn }
        Condition = {
          StringEquals = {
            "${local.issuer}:aud" = "sts.amazonaws.com"
            "${local.issuer}:sub" = subject
          }
        }
      }]
    })
  }

  read = [
    {
      Sid      = "ReadState"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = ["arn:aws:s3:::${var.state_bucket}", "arn:aws:s3:::${var.state_bucket}/*"]
    },
    {
      Sid      = "ReadOktaKey"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.okta_secret_arn]
    },
  ]
  write = [{
    Sid      = "WriteState"
    Effect   = "Allow"
    Action   = ["s3:PutObject", "s3:DeleteObject"] # DeleteObject: the state lock file
    Resource = ["arn:aws:s3:::${var.state_bucket}/*"]
  }]
}

resource "aws_iam_role" "plan" {
  name                 = "ai-entitlements-plan"
  description          = "GitHub Actions: terraform plan on pull requests. Read-only."
  assume_role_policy   = local.trust["plan"]
  max_session_duration = 3600
}

resource "aws_iam_role" "apply" {
  name                 = "ai-entitlements-apply"
  description          = "GitHub Actions: terraform apply from the protected environment."
  assume_role_policy   = local.trust["apply"]
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "plan" {
  name   = "plan"
  role   = aws_iam_role.plan.id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.read })
}

resource "aws_iam_role_policy" "apply" {
  name   = "apply"
  role   = aws_iam_role.apply.id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(local.read, local.write) })
}
