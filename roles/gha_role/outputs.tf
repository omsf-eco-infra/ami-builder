output "iam_role_name" {
  description = "Name of the IAM role that GitHub Actions will assume."
  value       = aws_iam_role.github_ami_builder.name
}

output "iam_role_arn" {
  description = "ARN of the IAM role for GitHub Actions."
  value       = aws_iam_role.github_ami_builder.arn
}

output "oidc_subject" {
  description = "First custom GitHub Actions OIDC subject string (index 0 of module.workflow_oidc.oidc_subjects) that is allowed to assume the role."
  value       = module.workflow_oidc.oidc_subjects[0]
}
