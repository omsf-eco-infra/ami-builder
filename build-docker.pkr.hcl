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

variable "build_singularity" {
  description = "Create a Singularity Image Format (SIF) image from the tagged Docker image. Requires Apptainer or Singularity on the Packer host."
  type        = bool
  default     = false
}

variable "singularity_output_directory" {
  description = "Directory where the generated SIF image and checksum are written."
  type        = string
  default     = "artifacts"

  validation {
    condition     = length(trimspace(var.singularity_output_directory)) > 0
    error_message = "The singularity_output_directory must be a non-empty path."
  }
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

variable "default_environment" {
  description = "Runtime environment to auto-activate by default."
  type        = string

  validation {
    condition     = length(trimspace(var.default_environment)) > 0 && can(regex("^[A-Za-z0-9_.-]+$", trimspace(var.default_environment)))
    error_message = "The default_environment must be a non-empty name using only letters, numbers, dot, underscore, or hyphen."
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

variable "build_timestamp" {
  description = "Build timestamp shared with workflow metadata so image tags and manifest output stay in sync."
  type        = string

  validation {
    condition     = length(trimspace(var.build_timestamp)) > 0 && can(regex("^[0-9]+$", trimspace(var.build_timestamp)))
    error_message = "The build_timestamp must be a non-empty integer timestamp string."
  }
}

locals {
  ami_base_name        = trimspace(var.ami_name)
  ami_name_suffix      = trimspace(var.ami_name_suffix)
  ami_base_with_suffix = local.ami_name_suffix == "" ? local.ami_base_name : "${local.ami_base_name}-${local.ami_name_suffix}"
  ami_name             = "${local.ami_base_with_suffix}-${var.build_timestamp}"

  environment_smoke_scripts = {
    for path in fileset(path.root, "environments/*/smoke-tests.sh") :
    basename(dirname(path)) => path
  }

  environment_full_scripts = {
    for path in fileset(path.root, "environments/*/full-tests.sh") :
    basename(dirname(path)) => path
  }

  available_environment_paths = {
    for env in sort(distinct(concat(
      keys(local.environment_smoke_scripts),
      keys(local.environment_full_scripts),
    ))) :
    env => "environments/${env}"
  }

  available_environment_names  = sort(keys(local.available_environment_paths))
  requested_environment_names  = length(var.environments) > 0 ? var.environments : local.available_environment_names
  normalized_environment_names = [for env in local.requested_environment_names : trimspace(env) if trimspace(env) != ""]
  enabled_environment_names    = distinct(local.normalized_environment_names)
  missing_environment_names    = [for env in local.enabled_environment_names : env if !contains(local.available_environment_names, env)]
  staged_environment_names     = [for env in local.enabled_environment_names : env if !contains(local.missing_environment_names, env)]

  missing_smoke_scripts = [
    for env in local.enabled_environment_names : env
    if length(trimspace(lookup(local.environment_smoke_scripts, env, ""))) == 0
  ]

  missing_full_scripts = [
    for env in local.enabled_environment_names : env
    if length(trimspace(lookup(local.environment_full_scripts, env, ""))) == 0
  ]

  default_environment = trimspace(var.default_environment)

  environments_label = length(local.enabled_environment_names) > 0 ? join(", ", local.enabled_environment_names) : "none"

  build_metadata = {
    ami_base_name        = local.ami_base_name
    ami_base_with_suffix = local.ami_base_with_suffix
    ami_name             = local.ami_name
    default_environment  = local.default_environment
    environments_label   = local.environments_label
    docker_tags          = jsonencode(local.tag_list)
    docker_image         = local.docker_image
    singularity_image    = var.build_singularity ? local.singularity_output_path : ""
  }

  remote_environment_root = "/tmp/environments"
  remote_pixi_manifest    = "${local.remote_environment_root}/pixi.toml"
  remote_pixi_lock        = "${local.remote_environment_root}/pixi.lock"
  remote_pixi_helper      = "${local.remote_environment_root}/pixi-environment-metadata.py"

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

  primary_tag = "${local.ami_base_with_suffix}-${var.build_timestamp}"
  tag_list    = [local.primary_tag]

  docker_image               = "${var.docker_repository}:${local.primary_tag}"
  singularity_output_path    = "${trimspace(var.singularity_output_directory)}/${local.primary_tag}.sif"

  label_changes = [for key, value in local.merged_labels : "LABEL ${key}=${jsonencode(value)}"]
}

source "docker" "this" {
  image  = var.docker_base_image
  commit = true
  changes = concat([
    "ENV OMSF_PIXI_WORKSPACE=/root",
    "ENV PIXI_DEFAULT_ENVIRONMENT=${local.default_environment}",
    "ENV OMSF_ENVIRONMENTS=\"${join(" ", local.enabled_environment_names)}\"",
    "ENV PIXI_HOME=/root/.pixi-global",
    "ENV CONDA_OVERRIDE_CUDA=12",
    "ENTRYPOINT [\"/usr/local/bin/omsf-entrypoint.sh\"]",
    "CMD [\"bash\", \"-l\"]",
  ], local.label_changes)
}

build {
  name    = local.ami_base_with_suffix
  sources = ["source.docker.this"]

  # ── Prerequisites ──────────────────────────────────────────────────
  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "echo '[install base] Installing prerequisite packages'",
      "set -euxo pipefail",
      "export DEBIAN_FRONTEND=noninteractive",
      "export TZ=Etc/UTC",
      "apt-get update",
      "apt-get install -y --no-install-recommends curl bzip2 ca-certificates python3 unzip",
      "rm -rf /var/lib/apt/lists/*",
    ]
  }

  # ── Pixi installation ─────────────────────────────────────────────
  provisioner "file" {
    source      = "build-scripts/lib.sh"
    destination = "/tmp/lib.sh"
  }

  provisioner "shell" {
    script = "build-scripts/install-pixi.sh"
    environment_vars = [
      "BUILD_ENV=docker",
    ]
  }

  # ── Copy environment files ─────────────────────────────────────────
  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "rm -rf \"${local.remote_environment_root}\"",
      "mkdir -p \"${local.remote_environment_root}\"",
    ]
  }

  provisioner "file" {
    source      = "environments/pixi.toml"
    destination = "${local.remote_pixi_manifest}"
  }

  provisioner "file" {
    source      = "environments/conda-pypi-map.json"
    destination = "${local.remote_environment_root}/conda-pypi-map.json"
  }

  provisioner "file" {
    source      = "environments/pixi.lock"
    destination = "${local.remote_pixi_lock}"
  }

  provisioner "file" {
    source      = "environments/pixi-environment-metadata.py"
    destination = "${local.remote_pixi_helper}"
  }

  dynamic "provisioner" {
    for_each = local.staged_environment_names
    labels   = ["file"]
    content {
      source      = local.available_environment_paths[provisioner.value]
      destination = local.remote_environment_root
    }
  }

  # ── Validation ─────────────────────────────────────────────────────
  provisioner "shell" {
    script = "build-scripts/validate-environments.sh"
    environment_vars = [
      "MISSING_ENVIRONMENTS=${join(" ", local.missing_environment_names)}",
      "MISSING_SMOKE=${join(" ", local.missing_smoke_scripts)}",
      "MISSING_FULL=${join(" ", local.missing_full_scripts)}",
      "ENVIRONMENT_DIRS=${local.environment_dirs_string}",
      "PIXI_MANIFEST_PATH=${local.remote_pixi_manifest}",
      "PIXI_METADATA_HELPER=${local.remote_pixi_helper}",
    ]
  }

  # ── Install pixi environments ─────────────────────────────────────
  provisioner "shell" {
    script = "build-scripts/setup-ami-pixi.sh"
    environment_vars = [
      "ENVIRONMENT_DIRS=${local.environment_dirs_string}",
      "DEFAULT_ENVIRONMENT=${local.default_environment}",
      "BUILD_ENV=docker",
      "CONDA_OVERRIDE_CUDA=12",
      "OMSF_PIXI_WORKSPACE=/root",
      "PIXI_HOME=/root/.pixi-global",
      "PIXI_MANIFEST_SOURCE=${local.remote_pixi_manifest}",
    ]
  }

  # ── Install entrypoint ─────────────────────────────────────────────
  provisioner "file" {
    source      = "build-scripts/docker-entrypoint.sh"
    destination = "/usr/local/bin/omsf-entrypoint.sh"
  }

  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "chmod 755 /usr/local/bin/omsf-entrypoint.sh",
    ]
  }

  # ── Smoke tests ────────────────────────────────────────────────────
  dynamic "provisioner" {
    for_each = local.enabled_environment_names
    labels   = ["shell"]
    content {
      script = "build-scripts/ami-pixi-smoke-test.sh"
      environment_vars = [
        "PIXI_ENV_NAME=${provisioner.value}",
        "BUILD_ENV=docker",
        "CONDA_OVERRIDE_CUDA=12",
        "OMSF_PIXI_WORKSPACE=/root",
        "PIXI_HOME=/root/.pixi-global",
        "KMP_AFFINITY=disabled",
        "OMP_NUM_THREADS=1",
        "OMP_PROC_BIND=false",
        "OMP_PLACES=cores",
      ]
      execute_command = "chmod +x '{{ .Path }}'; {{ .Vars }} '{{ .Path }}' '${local.remote_environment_root}/${provisioner.value}/smoke-tests.sh'"
    }
  }

  # ── Cleanup ────────────────────────────────────────────────────────
  # Keep /tmp/environments (test scripts are needed at container runtime).
  # The pixi.toml/pixi.lock duplication with /root is trivial.
  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "/usr/local/bin/pixi clean cache -y --no-progress || true",
      "rm -rf /var/lib/apt/lists/*",
    ]
  }

  # ── Post-processors ───────────────────────────────────────────────
  post-processors {
    post-processor "docker-tag" {
      repository = var.docker_repository
      tags       = local.tag_list
    }

    # The conversion must be chained after docker-tag so docker-daemon can
    # resolve the final repository:tag rather than Packer's temporary image.
    post-processor "shell-local" {
      script = "build-scripts/build-singularity-image.sh"
      environment_vars = [
        "BUILD_SINGULARITY=${var.build_singularity}",
        "DOCKER_IMAGE=${local.docker_image}",
        "SINGULARITY_IMAGE=${local.singularity_output_path}",
      ]
      execute_command = [
        "/bin/sh",
        "-c",
        "{{.Vars}} /usr/bin/env bash {{.Script}}",
      ]
    }
  }

  post-processor "manifest" {
    output      = "packer-docker-manifest.json"
    custom_data = local.build_metadata
  }
}
