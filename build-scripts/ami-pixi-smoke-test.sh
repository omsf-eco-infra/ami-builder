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
  echo "[ami_pixi_smoke_test] lib.sh not found" >&2
  exit 1
fi

ENVIRONMENT_DIR_ROOT="${ENVIRONMENT_DIR_ROOT:-/tmp/environments}"
workspace_root="${OMSF_PIXI_WORKSPACE:-$(resolve_target_home)}"
pixi_home="${PIXI_HOME:-${workspace_root}/.pixi-global}"
conda_override_cuda="${CONDA_OVERRIDE_CUDA:-12}"

if [[ -z "${PIXI_ENV_NAME:-}" ]]; then
  echo "[ami_pixi_smoke_test] PIXI_ENV_NAME must be set" >&2
  exit 1
fi

target_home="$(resolve_target_home)"
test_root="${ENVIRONMENT_DIR_ROOT}/${PIXI_ENV_NAME}"
default_smoke_test="${test_root}/smoke-tests.sh"

smoke_test="${1:-$default_smoke_test}"
if [[ ! -f "${smoke_test}" ]]; then
  echo "[ami_pixi_smoke_test] Smoke test script '${smoke_test}' not found" >&2
  exit 1
fi

echo "[ami_pixi_smoke_test] Running '${smoke_test}' in pixi environment '${PIXI_ENV_NAME}'"
run_as_target_user env \
  HOME="${target_home}" \
  PIXI_HOME="${pixi_home}" \
  CONDA_OVERRIDE_CUDA="${conda_override_cuda}" \
  /usr/local/bin/pixi run -m "${workspace_root}" -e "${PIXI_ENV_NAME}" --as-is bash "${smoke_test}"
echo "[ami_pixi_smoke_test] Smoke test finished."
