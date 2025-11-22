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
