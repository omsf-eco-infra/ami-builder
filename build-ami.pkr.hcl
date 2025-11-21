packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
}

variable "installs" {
  type    = list(string)
}

locals {
  ami_base_name = "dlami-${var.name}"
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

  ami_name        = "${local.ami_base_name}-{{timestamp}}"
  ami_description = "AWS DLAMI (Ubuntu) + ${join(", ", var.installs)}"

  ami_groups = ["all"]

  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_size = 200
    volume_type = "gp3"
    delete_on_termination = true
  }

  ami_block_device_mappings {
    device_name = "/dev/sda1"
    volume_size = 200
    volume_type = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = "${local.ami_base_name}"
    built_with  = "packer"
    environment = var.name
  }
}

build {
  name    = "dlami-${var.name}-build"
  sources = ["source.amazon-ebs.dlami"]

  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "sudo apt-get update",
      "sudo apt-get install -y curl bzip2",
    ]
  }

  provisioner "shell" {
    script = "build-scripts/install-micromamba.sh"
  }

  provisioner "shell" {
    script = "build-scripts/setup-env.sh"
  }
}
