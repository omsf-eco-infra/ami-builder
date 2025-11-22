locals {
  trimmed_workflow_filename = trimspace(var.workflow_filename)
  workflow_ref              = "${var.github_repository}/.github/workflows/${local.trimmed_workflow_filename}@${var.workflow_ref}"
  oidc_subject              = "repo:${var.github_repository}:job_workflow_ref:${local.workflow_ref}"
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "GitHubActionsAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.oidc_subject]
    }
  }
}

resource "terraform_data" "require_subject_claim_template" {
  lifecycle {
    precondition {
      condition     = var.subject_claim_template_configured
      error_message = "GitHub OIDC subject claim customization template must be created in the root module."
    }
  }
}
