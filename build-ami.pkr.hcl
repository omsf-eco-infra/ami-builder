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

variable "ami_name" {
  description = "Logical name for the AMI variant."
  type        = string

  validation {
    condition     = length(trimspace(var.ami_name)) > 0
    error_message = "The ami_name must be a non-empty string."
  }
}

variable "environments" {
  description = "Ordered list of environment directory names (under environments/) to include. Empty list means auto-discover all."
  type        = list(string)
  default     = []
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
  ami_base_name        = trimspace(var.ami_name)
  ami_name_suffix      = trimspace(var.ami_name_suffix)
  ami_base_with_suffix = "${local.ami_base_name}-${local.ami_name_suffix}"
  ami_name             = "${local.ami_base_with_suffix}-{{timestamp}}"

  available_environment_paths = {
    for path in fileset(path.root, "environments/*/environment.yaml") :
    basename(dirname(path)) => dirname(path)
  }

  available_environment_names      = sort(keys(local.available_environment_paths))
  requested_environment_names      = length(var.environments) > 0 ? var.environments : local.available_environment_names
  normalized_environment_names     = [for env in local.requested_environment_names : trimspace(env) if trimspace(env) != ""]
  enabled_environment_names        = sort(distinct(local.normalized_environment_names))
  missing_environment_names        = [for env in local.enabled_environment_names : env if !contains(local.available_environment_names, env)]

  remote_environment_root = "/tmp/environments"

  environment_directories = [for env in local.enabled_environment_names : "${local.remote_environment_root}/${env}"]
  environment_dirs_string = trimspace(join(" ", local.environment_directories))

  default_environment = length(local.enabled_environment_names) > 0 ? local.enabled_environment_names[0] : ""

  environments_label = length(local.enabled_environment_names) > 0 ? join(", ", local.enabled_environment_names) : "none"

  base_tags = {
    Name         = local.ami_base_with_suffix
    built_with   = "packer"
    managed_by   = "omsf-ami-builder"
    environment  = local.environments_label
    environments = local.environments_label
  }

  merged_tags = merge(local.base_tags, jsondecode(var.additional_tags))
}

source "amazon-ebs" "this" {
  region        = var.aws_region
  instance_type = "t3.large"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      architecture        = "x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }

    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  ssh_username = "ubuntu"

  ami_name        = local.ami_name
  ami_description = "[OMSF] Ubuntu + NVIDIA + environments: ${local.environments_label}"

  ami_groups = ["all"]

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  ami_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  aws_polling {
    max_attempts = 2000
  }

  run_tags = {
    Name         = "ami-builder-${local.ami_base_with_suffix}"
    template     = local.ami_base_with_suffix
    environment  = local.environments_label
    environments = local.environments_label
  }

  tags = local.merged_tags
}

build {
  name    = local.ami_base_with_suffix
  sources = ["source.amazon-ebs.this"]

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
      "set -euxo pipefail",
      "sudo apt-get install -y --no-install-recommends build-essential dkms linux-headers-$(uname -r) pciutils",
      "sudo apt-get install -y --no-install-recommends nvidia-dkms-550 nvidia-utils-550 nvidia-driver-550",
      "sudo systemctl enable nvidia-persistenced || true",
    ]
  }

  ## Micromamba environments
  provisioner "shell" {
    script = "build-scripts/install-micromamba.sh"
  }

  # copy over environment files and scripts
  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "sudo rm -rf \"${local.remote_environment_root}\"",
    ]
  }

  provisioner "file" {
    source      = "environments"
    destination = "/tmp"
  }

  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "if [ -d \"${local.remote_environment_root}\" ]; then",
      "  sudo chown -R ubuntu:ubuntu \"${local.remote_environment_root}\"",
      "fi",
    ]
  }

  # error handling
  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euo pipefail",
      "missing=\"${join(" ", local.missing_environment_names)}\"",
      "if [ -n \"$missing\" ]; then",
      "  echo \"[ami-builder] Missing environment directories for: $missing\" >&2",
      "  exit 1",
      "fi",
      "if [ -z \"${local.environment_dirs_string}\" ]; then",
      "  echo \"[ami-builder] No environments resolved from configuration.\" >&2",
      "  exit 1",
      "fi",
      "for env_dir in ${local.environment_dirs_string}; do",
      "  if [ ! -f \"$env_dir/environment.yaml\" ]; then",
      "    echo \"[ami-builder] Expected environment file $env_dir/environment.yaml not found\" >&2",
      "    exit 1",
      "  fi",
      "done",
    ]
  }

  provisioner "shell" {
    script = "build-scripts/setup-env.sh"
    environment_vars = [
      "ENVIRONMENT_DIRS=${local.environment_dirs_string}",
      "DEFAULT_ENVIRONMENT=${local.default_environment}",
    ]
  }

  ## Smoke tests
  provisioner "shell" {
    script = "build-scripts/nvidia-smoke-test.sh"
  }

  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "sudo mkdir -p /tmp/smoke-tests",
      "sudo chown ubuntu:ubuntu /tmp/smoke-tests",
    ]
  }

  provisioner "file" {
    source      = "smoke-tests/${local.default_environment}.sh"
    destination = "/tmp/smoke-tests/${local.default_environment}.sh"
  }

  provisioner "shell" {
    script = "build-scripts/smoke-test.sh"
    environment_vars = [
      "MICROMAMBA_ENV_NAME=${local.default_environment}",
    ]
  }
}
