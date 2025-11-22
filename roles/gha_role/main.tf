data "github_repository" "target" {
  full_name = var.github_repository
}

module "workflow_oidc" {
  source = "../modules/github_actions_oidc"
  providers = {
    github = github
  }

  github_repository             = var.github_repository
  workflow_filename             = var.workflow_filename
  workflow_ref                  = var.workflow_ref
  github_oidc_provider_arn      = var.github_oidc_provider_arn
  subject_claim_template_configured = var.subject_claim_template_configured
}

resource "aws_iam_role" "github_ami_builder" {
  name                  = var.role_name
  assume_role_policy    = module.workflow_oidc.assume_role_policy
  max_session_duration  = 7200
  description           = "Role assumed by GitHub Actions to build machine images via Packer."
  force_detach_policies = true
  tags                  = var.tags
}

data "aws_iam_policy_document" "packer_permissions" {
  statement {
    sid    = "EC2AmiBuild"
    effect = "Allow"
    actions = [
      "ec2:AttachVolume",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CopyImage",
      "ec2:CreateImage",
      "ec2:CreateKeyPair",
      "ec2:CreateSecurityGroup",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:DeleteKeyPair",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSnapshot",
      "ec2:DeleteTags",
      "ec2:DeleteVolume",
      "ec2:DeregisterImage",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceAttribute",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeRegions",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSnapshots",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2:DescribeVpcs",
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeKeyPairs",
      "ec2:DetachVolume",
      "ec2:GetConsoleOutput",
      "ec2:ModifyImageAttribute",
      "ec2:ModifyInstanceAttribute",
      "ec2:RegisterImage",
      "ec2:RunInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "packer" {
  name   = "${var.role_name}-packer"
  role   = aws_iam_role.github_ami_builder.id
  policy = data.aws_iam_policy_document.packer_permissions.json
}

resource "github_actions_secret" "role_arn" {
  repository    = data.github_repository.target.name
  secret_name   = var.role_secret_name
  plaintext_value = aws_iam_role.github_ami_builder.arn
}
