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

  validation {
    condition     = alltrue([for env in var.environments : length(trimspace(env)) > 0 && can(regex("^[A-Za-z0-9_.-]+$", trimspace(env)))])
    error_message = "Environments must contain non-empty names using only letters, numbers, dot, underscore, or hyphen."
  }
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

  environment_smoke_scripts = {
    for path in fileset(path.root, "environments/*/smoke-tests.sh") :
    basename(dirname(path)) => path
  }

  environment_full_scripts = {
    for path in fileset(path.root, "environments/*/full-tests.sh") :
    basename(dirname(path)) => path
  }

  environment_matrix = [
    for env in local.enabled_environment_names : {
      name         = env
      smoke_script = trimspace(lookup(local.environment_smoke_scripts, env, ""))
      full_script  = trimspace(lookup(local.environment_full_scripts, env, ""))
    }
  ]

  environment_matrix_json = jsonencode(local.environment_matrix)

  missing_smoke_scripts = [
    for item in local.environment_matrix : item.name
    if length(item.smoke_script) == 0
  ]

  missing_full_scripts = [
    for item in local.environment_matrix : item.name
    if length(item.full_script) == 0
  ]

  default_environment = length(local.enabled_environment_names) > 0 ? local.enabled_environment_names[0] : ""

  environments_label = length(local.enabled_environment_names) > 0 ? join(", ", local.enabled_environment_names) : "none"

  build_metadata = {
    ami_base_name        = local.ami_base_name
    ami_base_with_suffix = local.ami_base_with_suffix
    ami_name             = local.ami_name
    default_environment  = local.default_environment
    environments_label   = local.environments_label
    environment_matrix   = local.environment_matrix_json
  }

  remote_environment_root = "/tmp/environments"

  environment_directories = [for env in local.enabled_environment_names : "${local.remote_environment_root}/${env}"]
  environment_dirs_string = trimspace(join(" ", local.environment_directories))

  base_tags = {
    Name         = local.ami_base_with_suffix
    built_with   = "packer"
    managed_by   = "omsf-ami-builder"
    environments = local.environments_label
    status       = "ephemeral"
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

  ami_groups = []

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
  provisioner "file" {
    source      = "build-scripts/lib.sh"
    destination = "/tmp/lib.sh"
  }

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

  # environment validation
  provisioner "shell" {
    script = "build-scripts/validate-environments.sh"
    environment_vars = [
      "MISSING_ENVIRONMENTS=${join(" ", local.missing_environment_names)}",
      "MISSING_SMOKE=${join(" ", local.missing_smoke_scripts)}",
      "MISSING_FULL=${join(" ", local.missing_full_scripts)}",
      "ENVIRONMENT_DIRS=${local.environment_dirs_string}",
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

  dynamic "provisioner" {
    for_each = local.enabled_environment_names
    labels   = ["shell"]
    content {
      script = "build-scripts/smoke-test.sh"
      environment_vars = [
        "MICROMAMBA_ENV_NAME=${provisioner.value}",
      ]
      execute_command = "chmod +x '{{ .Path }}'; {{ .Vars }} '{{ .Path }}' '${local.remote_environment_root}/${provisioner.value}/smoke-tests.sh'"
    }
  }

  post-processor "manifest" {
    output      = "packer-manifest.json"
    custom_data = local.build_metadata
  }
}
