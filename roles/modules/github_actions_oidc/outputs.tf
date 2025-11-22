output "oidc_subject" {
  description = "Custom GitHub Actions OIDC subject string that is allowed to assume the role."
  value       = local.oidc_subject
}

output "assume_role_policy" {
  description = "IAM policy document JSON that allows the configured GitHub workflow to assume the role."
  value       = data.aws_iam_policy_document.assume_role.json
}
