#!/usr/bin/env bash
set -euo pipefail

BUILD_ENV="${BUILD_ENV:-ami}"
if [[ "${BUILD_ENV}" == "docker" ]]; then
  TARGET_USER="root"
  TARGET_GROUP="root"
  USE_SUDO="false"
else
  TARGET_USER="ubuntu"
  TARGET_GROUP="ubuntu"
  USE_SUDO="true"
fi
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-/opt/micromamba}"

maybe_sudo() {
  if [[ "${USE_SUDO}" == "true" && "$(id -u)" -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

echo "[install_micromamba] Installing micromamba into /usr/local/bin and preparing ${MAMBA_ROOT_PREFIX}"

# Download and install micromamba
tmpdir="$(mktemp -d)"
pushd "$tmpdir" >/dev/null

curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj bin/micromamba
maybe_sudo mv bin/micromamba /usr/local/bin/micromamba
maybe_sudo chmod 755 /usr/local/bin/micromamba

popd >/dev/null
rm -rf "$tmpdir"

# Create a root prefix for micromamba and give it to the target user
maybe_sudo mkdir -p "${MAMBA_ROOT_PREFIX}"
maybe_sudo chown "${TARGET_USER}:${TARGET_GROUP}" "${MAMBA_ROOT_PREFIX}"

echo "[install_micromamba] Done."
