#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=build-scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

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
