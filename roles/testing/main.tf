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

resource "aws_cloudwatch_log_group" "test_logs" {
  name              = var.cloudwatch_log_group_name
  retention_in_days = var.cloudwatch_log_group_retention_in_days
  tags              = var.tags
}

resource "aws_security_group" "test_instances" {
  name                   = var.security_group_name
  description            = "Egress-only security group for AMI test instances."
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  egress {
    description      = "Allow HTTPS egress for SSM and CloudWatch Logs."
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = var.tags
}

data "aws_iam_policy_document" "test_instance_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "test_instance" {
  name                  = var.instance_role_name
  assume_role_policy    = data.aws_iam_policy_document.test_instance_assume_role.json
  description           = "Instance role for AMI test hosts (SSM + CloudWatch Logs)."
  force_detach_policies = true
  tags                  = var.tags
}

resource "aws_iam_role_policy_attachment" "test_instance_ssm" {
  role       = aws_iam_role.test_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "test_instance_logs" {
  statement {
    sid    = "StreamCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:PutLogEvents"
    ]
    resources = [
      aws_cloudwatch_log_group.test_logs.arn,
      "${aws_cloudwatch_log_group.test_logs.arn}:*"
    ]
  }

  statement {
    sid     = "DescribeLogGroups"
    effect  = "Allow"
    actions = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "test_instance_logs" {
  name   = "${var.instance_role_name}-logs"
  role   = aws_iam_role.test_instance.id
  policy = data.aws_iam_policy_document.test_instance_logs.json
}

resource "aws_iam_instance_profile" "test_instance" {
  name = var.instance_profile_name
  role = aws_iam_role.test_instance.name
  tags = var.tags
}

data "aws_iam_policy_document" "test_runner" {
  statement {
    sid    = "Ec2Lifecycle"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceAttribute",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeImages",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeRegions",
      "ec2:DescribeTags",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:CreateVolume",
      "ec2:DescribeVolumes"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "SendSsmCommands"
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:ListCommands",
      "ssm:CancelCommand"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogGroup"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DescribeLogGroups"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogStreams"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:PutLogEvents"
    ]
    resources = [
      aws_cloudwatch_log_group.test_logs.arn,
      "${aws_cloudwatch_log_group.test_logs.arn}:*"
    ]
  }

  statement {
    sid    = "PassInstanceRole"
    effect = "Allow"
    actions = ["iam:PassRole"]
    resources = [aws_iam_role.test_instance.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_ami_test_runner" {
  name                  = var.test_runner_role_name
  assume_role_policy    = module.workflow_oidc.assume_role_policy
  max_session_duration  = 7200
  description           = "Role assumed by GitHub Actions to launch AMI tests via SSM."
  force_detach_policies = true
  tags                  = var.tags
}

resource "aws_iam_role_policy" "test_runner_permissions" {
  name   = "${var.test_runner_role_name}-runner"
  role   = aws_iam_role.github_ami_test_runner.id
  policy = data.aws_iam_policy_document.test_runner.json
}

resource "github_actions_secret" "test_runner_role_arn" {
  repository      = data.github_repository.target.name
  secret_name     = var.test_runner_role_secret_name
  plaintext_value = aws_iam_role.github_ami_test_runner.arn
}
