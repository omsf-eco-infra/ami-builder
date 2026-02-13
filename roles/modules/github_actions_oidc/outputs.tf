output "oidc_subjects" {
  description = "Custom GitHub Actions OIDC subject strings that are allowed to assume the role."
  value       = local.oidc_subjects
}

output "assume_role_policy" {
  description = "IAM policy document JSON that allows the configured GitHub workflow to assume the role."
  value       = data.aws_iam_policy_document.assume_role.json
}
