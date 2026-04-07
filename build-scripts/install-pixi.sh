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
  echo "[install_pixi] lib.sh not found" >&2
  exit 1
fi

PIXI_VERSION="${PIXI_VERSION:-v0.63.0}"
export PIXI_VERSION

target_home="$(resolve_target_home)"
pixi_home="${PIXI_HOME:-${target_home}/.pixi-global}"
tmpdir="$(mktemp -d)"
installer="${tmpdir}/install.sh"

echo "[install_pixi] Installing pixi ${PIXI_VERSION} into /usr/local/bin"
echo "[install_pixi] Using PIXI_HOME=${pixi_home}"

curl -fsSL https://pixi.sh/install.sh -o "${installer}"
maybe_sudo env \
  PIXI_VERSION="${PIXI_VERSION}" \
  PIXI_HOME="${pixi_home}" \
  PIXI_BIN_DIR="/usr/local/bin" \
  PIXI_NO_PATH_UPDATE="1" \
  bash "${installer}"

maybe_sudo mkdir -p "${pixi_home}"
maybe_sudo chown -R "${TARGET_USER}:${TARGET_GROUP}" "${pixi_home}"
maybe_sudo chmod 755 /usr/local/bin/pixi

rm -rf "${tmpdir}"

echo "[install_pixi] Done."
