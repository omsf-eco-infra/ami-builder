#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
  # shellcheck source=build-scripts/lib.sh
  source "${SCRIPT_DIR}/lib.sh"
elif [[ -f "/tmp/lib.sh" ]]; then
  # shellcheck source=/tmp/lib.sh
  source "/tmp/lib.sh"
else
  echo "[setup_ami_pixi] lib.sh not found" >&2
  exit 1
fi

if [[ -z "${ENVIRONMENT_DIRS:-}" ]]; then
  echo "[setup_ami_pixi] ENVIRONMENT_DIRS must be set" >&2
  exit 1
fi

if [[ -z "${DEFAULT_ENVIRONMENT:-}" ]]; then
  echo "[setup_ami_pixi] DEFAULT_ENVIRONMENT must be set" >&2
  exit 1
fi

workspace_root="${OMSF_PIXI_WORKSPACE:-$(resolve_target_home)}"
pixi_home="${PIXI_HOME:-${workspace_root}/.pixi-global}"
conda_override_cuda="${CONDA_OVERRIDE_CUDA:-12}"
manifest_source="${PIXI_MANIFEST_SOURCE:-/tmp/environments/pixi.toml}"
lock_source="${PIXI_LOCK_SOURCE:-${manifest_source%/*}/pixi.lock}"
conda_pypi_map_source="${CONDA_PYPI_MAP_SOURCE:-${manifest_source%/*}/conda-pypi-map.json}"
target_manifest="${workspace_root}/pixi.toml"
target_lock="${workspace_root}/pixi.lock"
target_conda_pypi_map="${workspace_root}/conda-pypi-map.json"
target_home="$(resolve_target_home)"

read -r -a env_dirs <<< "${ENVIRONMENT_DIRS}"

if [[ ${#env_dirs[@]} -eq 0 ]]; then
  echo "[setup_ami_pixi] ENVIRONMENT_DIRS must include at least one directory" >&2
  exit 1
fi

if [[ ! -f "${manifest_source}" ]]; then
  echo "[setup_ami_pixi] Pixi manifest not found at ${manifest_source}" >&2
  exit 1
fi

if [[ ! -f "${lock_source}" ]]; then
  echo "[setup_ami_pixi] Pixi lock file not found at ${lock_source}" >&2
  exit 1
fi

echo "[setup_ami_pixi] Preparing workspace at ${workspace_root}"
maybe_sudo mkdir -p "${workspace_root}" "${pixi_home}"
maybe_sudo cp "${manifest_source}" "${target_manifest}"
maybe_sudo cp "${lock_source}" "${target_lock}"
if [[ -f "${conda_pypi_map_source}" ]]; then
  maybe_sudo cp "${conda_pypi_map_source}" "${target_conda_pypi_map}"
  maybe_sudo chown "${TARGET_USER}:${TARGET_GROUP}" "${target_conda_pypi_map}"
fi
maybe_sudo chown "${TARGET_USER}:${TARGET_GROUP}" "${target_manifest}" "${target_lock}"
maybe_sudo chown -R "${TARGET_USER}:${TARGET_GROUP}" "${pixi_home}"

default_env_name="${DEFAULT_ENVIRONMENT}"
available_envs=()
default_env_found=false

for env_dir in "${env_dirs[@]}"; do
  [[ -z "${env_dir:-}" ]] && continue
  env_dir="${env_dir%/}"
  env_basename="$(basename "${env_dir}")"
  smoke_test="${env_dir}/smoke-tests.sh"
  full_test="${env_dir}/full-tests.sh"
  post_install="${env_dir}/post-install.sh"

  if [[ ! -f "${smoke_test}" ]]; then
    echo "[setup_ami_pixi] Missing smoke-tests.sh for '${env_basename}' at ${smoke_test}" >&2
    exit 1
  fi

  if [[ ! -f "${full_test}" ]]; then
    echo "[setup_ami_pixi] Missing full-tests.sh for '${env_basename}' at ${full_test}" >&2
    exit 1
  fi

  if [[ ! -f "${post_install}" ]]; then
    echo "[setup_ami_pixi] Missing post-install.sh for '${env_basename}' at ${post_install}" >&2
    exit 1
  fi

  echo "[setup_ami_pixi] Installing runtime environment '${env_basename}' from ${target_manifest}"
  run_as_target_user env \
    HOME="${target_home}" \
    PIXI_HOME="${pixi_home}" \
    CONDA_OVERRIDE_CUDA="${conda_override_cuda}" \
    /usr/local/bin/pixi install --frozen -m "${target_manifest}" -e "${env_basename}" --no-progress

  available_envs+=("${env_basename}")
  if [[ "${env_basename}" == "${default_env_name}" ]]; then
    default_env_found=true
  fi
done

if [[ "${default_env_found}" == false ]]; then
  echo "[setup_ami_pixi] DEFAULT_ENVIRONMENT '${default_env_name}' not found in ENVIRONMENT_DIRS" >&2
  exit 1
fi

available_envs_str=""
if [[ ${#available_envs[@]} -gt 0 ]]; then
  printf -v available_envs_str '%s ' "${available_envs[@]}"
  available_envs_str="${available_envs_str% }"
fi

profile_script="/etc/profile.d/omsf-pixi.sh"

echo "[setup_ami_pixi] Writing ${profile_script}"
maybe_sudo tee "${profile_script}" >/dev/null <<EOF
export OMSF_PIXI_WORKSPACE="${workspace_root}"
export OMSF_ENVIRONMENTS="${available_envs_str}"
export PIXI_DEFAULT_ENVIRONMENT="${default_env_name}"
export PIXI_HOME="${pixi_home}"
export CONDA_OVERRIDE_CUDA="${conda_override_cuda}"
EOF
maybe_sudo chmod 644 "${profile_script}"

target_profile="${target_home}/.profile"
run_as_target_user touch "${target_profile}"
run_as_target_user sed -i '/# >>> omsf pixi auto-activation >>>/,/# <<< omsf pixi auto-activation <<</d' "${target_profile}"
run_as_target_user tee -a "${target_profile}" >/dev/null <<'EOF'

# >>> omsf pixi auto-activation >>>
if [ -f /etc/profile.d/omsf-pixi.sh ]; then
  # shellcheck source=/etc/profile.d/omsf-pixi.sh
  . /etc/profile.d/omsf-pixi.sh
fi
if command -v pixi >/dev/null 2>&1 && [ -n "${PIXI_DEFAULT_ENVIRONMENT:-}" ] && [ "${PIXI_IN_SHELL:-0}" != "1" ]; then
  eval "$(pixi shell-hook -m "${OMSF_PIXI_WORKSPACE}" -e "${PIXI_DEFAULT_ENVIRONMENT}" --shell bash --as-is --no-completions)"
fi
# <<< omsf pixi auto-activation <<<
EOF

echo "[setup_ami_pixi] Cleaning pixi cache"
run_as_target_user env \
  HOME="${target_home}" \
  PIXI_HOME="${pixi_home}" \
  CONDA_OVERRIDE_CUDA="${conda_override_cuda}" \
  /usr/local/bin/pixi clean cache -y --no-progress || true

echo "[setup_ami_pixi] Done."
