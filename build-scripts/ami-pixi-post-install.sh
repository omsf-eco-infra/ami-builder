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
  echo "[ami_pixi_post_install] lib.sh not found" >&2
  exit 1
fi

ENVIRONMENT_DIR_ROOT="${ENVIRONMENT_DIR_ROOT:-/tmp/environments}"
workspace_root="${OMSF_PIXI_WORKSPACE:-$(resolve_target_home)}"
pixi_home="${PIXI_HOME:-${workspace_root}/.pixi-global}"
conda_override_cuda="${CONDA_OVERRIDE_CUDA:-12}"
target_home="$(resolve_target_home)"

if [[ -z "${PIXI_ENV_NAME:-}" ]]; then
  echo "[ami_pixi_post_install] PIXI_ENV_NAME must be set" >&2
  exit 1
fi

post_install_root="${ENVIRONMENT_DIR_ROOT}/${PIXI_ENV_NAME}"
default_post_install="${post_install_root}/post-install.sh"
post_install_script="${1:-$default_post_install}"

if [[ ! -f "${post_install_script}" ]]; then
  echo "[ami_pixi_post_install] Post-install script '${post_install_script}' not found" >&2
  exit 1
fi

echo "[ami_pixi_post_install] Running '${post_install_script}' in pixi environment '${PIXI_ENV_NAME}'"
env \
  HOME="${target_home}" \
  PIXI_HOME="${pixi_home}" \
  CONDA_OVERRIDE_CUDA="${conda_override_cuda}" \
  BUILD_ENV="${BUILD_ENV:-ami}" \
  OMSF_PIXI_WORKSPACE="${workspace_root}" \
  ENVIRONMENT_DIR_ROOT="${ENVIRONMENT_DIR_ROOT}" \
  PIXI_ENV_NAME="${PIXI_ENV_NAME}" \
  /usr/local/bin/pixi run -m "${workspace_root}" -e "${PIXI_ENV_NAME}" --as-is bash "${post_install_script}"
echo "[ami_pixi_post_install] Post-install finished."
