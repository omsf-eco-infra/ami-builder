output "test_runner_role_name" {
  description = "Name of the IAM role that GitHub Actions will assume for AMI testing."
  value       = aws_iam_role.github_ami_test_runner.name
}

output "test_runner_role_arn" {
  description = "ARN of the IAM role for GitHub Actions AMI testing."
  value       = aws_iam_role.github_ami_test_runner.arn
}

output "test_runner_oidc_subject" {
  description = "Custom GitHub Actions OIDC subject string that is allowed to assume the AMI test runner role."
  value       = module.workflow_oidc.oidc_subject
}

output "instance_role_name" {
  description = "Name of the IAM role attached to AMI test instances."
  value       = aws_iam_role.test_instance.name
}

output "instance_role_arn" {
  description = "ARN of the IAM role attached to AMI test instances."
  value       = aws_iam_role.test_instance.arn
}

output "instance_profile_name" {
  description = "Name of the IAM instance profile attached to AMI test instances."
  value       = aws_iam_instance_profile.test_instance.name
}

output "security_group_id" {
  description = "ID of the security group used by AMI test instances."
  value       = aws_security_group.test_instances.id
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch Logs group used for test output."
  value       = aws_cloudwatch_log_group.test_logs.name
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch Logs group used for test output."
  value       = aws_cloudwatch_log_group.test_logs.arn
}
