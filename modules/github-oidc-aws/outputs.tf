output "plan_role_arn" {
  description = "Set as the repository variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as the repository variable AWS_APPLY_ROLE_ARN."
  value       = aws_iam_role.apply.arn
}

output "trusted_subjects" {
  description = "Exactly which GitHub jobs may assume each role."
  value       = local.subjects
}
