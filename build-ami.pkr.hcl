packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "aws_region" {
  description = "AWS region where the AMI build will run."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Logical name for the AMI variant (also used for environment names)."
  type        = string
}

variable "installs" {
  description = "List of micromamba packages to install into the AMI image."
  type        = list(string)
}

variable "ami_name_suffix" {
  description = "Optional suffix appended to the AMI base name; hyphen is added automatically if needed."
  type        = string
  default     = ""
}

variable "additional_tags" {
  description = "JSON string of additional AMI tags merged with the default tag set."
  type        = string
  default     = "{}"
}

locals {
  ami_base_name        = "dlami-${var.name}"
  ami_name_suffix      = trimspace(var.ami_name_suffix)
  ami_base_with_suffix = "${local.ami_base_name}-${local.ami_name_suffix}"
  ami_name             = "${local.ami_base_name}-${local.ami_name_suffix}-{{timestamp}}"
  base_tags = {
    Name        = local.ami_base_with_suffix
    built_with  = "packer"
    environment = var.name
  }
  merged_tags = merge(local.base_tags, jsondecode(var.additional_tags))
}

source "amazon-ebs" "dlami" {
  region        = var.aws_region
  instance_type = "t3.large"

  source_ami_filter {
    filters = {
      name                = "Deep Learning OSS Nvidia Driver AMI GPU PyTorch * (Ubuntu 22.04) *"
      architecture        = "x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }

    owners      = ["amazon"]
    most_recent = true
  }

  ssh_username = "ubuntu"

  ami_name        = local.ami_name
  ami_description = "AWS DLAMI (Ubuntu) + ${join(", ", var.installs)}"

  ami_groups = ["all"]

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 200
    volume_type           = "gp3"
    delete_on_termination = true
  }

  ami_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 200
    volume_type           = "gp3"
    delete_on_termination = true
  }

  aws_polling {
    # large AMIs can take a while to become available
    max_attempts = 2000
  }

  run_tags = {
    Name        = "packer-ami-build"
    template    = local.ami_base_with_suffix
    environment = var.name
  }

  tags = local.merged_tags
}

build {
  name    = "${var.name}-build"
  sources = ["source.amazon-ebs.dlami"]

  ## Linux environment
  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "echo '[install base] Installing prerequisite packages'",
      "set -euxo pipefail",
      "sudo apt-get update",
      "sudo apt-get install -y curl bzip2",
    ]
  }

  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "echo '[install ssm agent] Installing AWS SSM Agent for remote management'",
      "set -euxo pipefail",
      "sudo snap install amazon-ssm-agent --classic",
      "sudo systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service",
    ]
  }

  ## Micromamba environment
  provisioner "shell" {
    script = "build-scripts/install-micromamba.sh"
  }

  provisioner "shell" {
    script = "build-scripts/setup-env.sh"
    environment_vars = [
      "MICROMAMBA_PACKAGES=${join(" ", var.installs)}",
      "MICROMAMBA_ENV_NAME=${var.name}",
    ]
  }

  ## Smoke tests
  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "sudo mkdir -p /tmp/smoke-tests",
      "sudo chown ubuntu:ubuntu /tmp/smoke-tests",
    ]
  }

  provisioner "file" {
    source      = "smoke-tests/${var.name}.sh"
    destination = "/tmp/smoke-tests/${var.name}.sh"
  }

  provisioner "shell" {
    script = "build-scripts/smoke-test.sh"
    environment_vars = [
      "MICROMAMBA_ENV_NAME=${var.name}",
    ]
  }
}
