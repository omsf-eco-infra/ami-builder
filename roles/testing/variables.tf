variable "github_repository" {
  description = "Full name of the GitHub repository (e.g. owner/repo) whose workflow assumes this role."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "Repository must be in the form owner/repo."
  }
}

variable "workflow_filename" {
  description = "GitHub Actions workflow filename (under .github/workflows) that should be allowed to assume the IAM role."
  type        = string

  validation {
    condition     = length(trimspace(var.workflow_filename)) > 0
    error_message = "Workflow filename cannot be empty."
  }
}

variable "workflow_ref" {
  description = "Git ref (e.g. refs/heads/main or refs/heads/*) of the workflow that assumes the IAM role; wildcards are allowed via StringLike."
  type        = string
  default     = "refs/heads/main"

  validation {
    condition     = can(regex("^refs/", var.workflow_ref))
    error_message = "Workflow ref must start with refs/ (e.g. refs/heads/main or refs/heads/*)."
  }
}

variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider that is already configured in AWS."
  type        = string
}

variable "subject_claim_template_configured" {
  description = "Set to true when the repository OIDC subject claim customization template is already managed (outside this module); required so callers explicitly acknowledge it."
  type        = bool
}

variable "test_runner_role_name" {
  description = "Name to assign to the IAM role that GitHub Actions will assume for AMI testing."
  type        = string
  default     = "github-actions-ami-testing"
}

variable "test_runner_role_secret_name" {
  description = "GitHub Actions secret name to store the AMI test runner role ARN."
  type        = string
  default     = "AWS_TEST_ASSUME_ROLE_ARN"
}

variable "instance_role_name" {
  description = "Name for the IAM role attached to test instances."
  type        = string
  default     = "ami-test-instance-role"
}

variable "instance_profile_name" {
  description = "Name for the IAM instance profile attached to test instances."
  type        = string
  default     = "ami-test-instance-profile"
}

variable "instance_profile_secret_name" {
  description = "GitHub Actions secret name that stores the AMI test instance profile name."
  type        = string
  default     = "TEST_MAIN_INSTANCE_PROFILE_NAME"
}

variable "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch Logs group used for test output."
  type        = string
  default     = "/ami-tests"
}

variable "cloudwatch_log_group_secret_name" {
  description = "GitHub Actions secret name that stores the AMI test CloudWatch Logs group name."
  type        = string
  default     = "TEST_MAIN_LOG_GROUP_NAME"
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Retention period (in days) for the CloudWatch Logs group."
  type        = number
  default     = 30
}

variable "security_group_name" {
  description = "Name of the security group used by AMI test instances."
  type        = string
  default     = "ami-test-ssm-egress"
}

variable "security_group_secret_name" {
  description = "GitHub Actions secret name that stores the AMI test security group ID."
  type        = string
  default     = "TEST_MAIN_SECURITY_GROUP_ID"
}

variable "vpc_id" {
  description = "ID of the VPC where AMI test instances run."
  type        = string
}

variable "tags" {
  description = "Optional tags that should be added to created AWS resources."
  type        = map(string)
  default     = {}
}
