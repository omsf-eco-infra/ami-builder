packer {
  required_plugins {
    docker = {
      source  = "github.com/hashicorp/docker"
      version = ">= 1.0.0"
    }
  }
}

variable "docker_base_image" {
  description = "Base CUDA image to build from."
  type        = string
  default     = "nvidia/cuda:12.8.0-runtime-ubuntu24.04"
}

variable "docker_repository" {
  description = "Target Docker repository (e.g., ghcr.io/org/image)."
  type        = string
  default     = "ghcr.io/omsf-eco-infra/omsf"
}

variable "ami_name" {
  description = "Logical name for the Docker image variant (matches AMI naming)."
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
  description = "Optional suffix appended to the AMI/Docker base name; hyphen is added automatically if needed."
  type        = string
  default     = ""
}

variable "additional_tags" {
  description = "JSON string of additional metadata tags merged with the default label set."
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
    docker_tags          = jsonencode(local.tag_list)
  }

  remote_environment_root = "/tmp/environments"

  environment_directories = [for env in local.enabled_environment_names : "${local.remote_environment_root}/${env}"]
  environment_dirs_string = trimspace(join(" ", local.environment_directories))

  base_labels = {
    Name         = local.ami_base_with_suffix
    built_with   = "packer"
    managed_by   = "omsf-ami-builder"
    environments = local.environments_label
    status       = "ephemeral"
  }

  merged_labels = merge(local.base_labels, local.build_metadata, jsondecode(var.additional_tags))

  primary_tag = "${local.ami_base_with_suffix}-{{timestamp}}"
  date_tag    = formatdate("YYYYMMDD", timestamp())
  tag_list    = distinct([local.primary_tag, local.ami_base_with_suffix, local.date_tag, "latest"])

  label_changes = [for key, value in local.merged_labels : "LABEL ${key}=${jsonencode(value)}"]
}

source "docker" "this" {
  image  = var.docker_base_image
  commit = true
  changes = concat([
    "ENV MAMBA_ROOT_PREFIX=/opt/micromamba",
    "ENV MICROMAMBA_DEFAULT_ENVIRONMENT=${local.default_environment}",
    "ENV MICROMAMBA_ENVIRONMENTS=${join(" ", local.enabled_environment_names)}",
    "ENTRYPOINT [\"/usr/local/bin/omsf-entrypoint.sh\"]",
    "CMD [\"bash\", \"-l\"]",
  ], local.label_changes)
}

build {
  name    = local.ami_base_with_suffix
  sources = ["source.docker.this"]

  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "echo '[install base] Installing prerequisite packages'",
      "set -euxo pipefail",
      "apt-get update",
      "apt-get install -y --no-install-recommends curl bzip2 ca-certificates",
      "rm -rf /var/lib/apt/lists/*",
    ]
  }

  provisioner "file" {
    source      = "build-scripts/lib.sh"
    destination = "/tmp/lib.sh"
  }

  provisioner "shell" {
    script = "build-scripts/install-micromamba.sh"
    environment_vars = [
      "BUILD_ENV=docker",
      "MAMBA_ROOT_PREFIX=/opt/micromamba",
    ]
  }

  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "rm -rf \"${local.remote_environment_root}\"",
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
      "  chown -R root:root \"${local.remote_environment_root}\"",
      "fi",
    ]
  }

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
      "BUILD_ENV=docker",
      "MAMBA_ROOT_PREFIX=/opt/micromamba",
      "MAMBA_EXTRACT_THREADS=1",
      "MAMBA_DOWNLOAD_THREADS=1",
      "MAMBA_NO_BANNER=1",
    ]
  }

  provisioner "file" {
    source      = "build-scripts/docker-entrypoint.sh"
    destination = "/usr/local/bin/omsf-entrypoint.sh"
  }

  dynamic "provisioner" {
    for_each = local.enabled_environment_names
    labels   = ["shell"]
    content {
      script = "build-scripts/smoke-test.sh"
      environment_vars = [
        "MICROMAMBA_ENV_NAME=${provisioner.value}",
        "BUILD_ENV=docker",
        "MAMBA_ROOT_PREFIX=/opt/micromamba",
        "ENVIRONMENT_DIR_ROOT=${local.remote_environment_root}",
        "KMP_AFFINITY=disabled",
        "OMP_NUM_THREADS=1",
        "OMP_PROC_BIND=false",
        "OMP_PLACES=cores",
      ]
      execute_command = "chmod +x '{{ .Path }}'; {{ .Vars }} '{{ .Path }}' '${local.remote_environment_root}/${provisioner.value}/smoke-tests.sh'"
    }
  }

  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "/usr/local/bin/micromamba clean -a -y || true",
    ]
  }

  post-processor "docker-tag" {
    repository = var.docker_repository
    tags       = local.tag_list
  }

  post-processor "manifest" {
    output      = "packer-docker-manifest.json"
    custom_data = local.build_metadata
  }
}
