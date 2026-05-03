#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_env="${BUILD_ENV:-ami}"

if [[ -f "${SCRIPT_DIR}/../../build-scripts/lib.sh" ]]; then
  # Local repo execution path: the script is being run from the checked-out
  # source tree, so we can source the shared helpers directly.
  # shellcheck source=build-scripts/lib.sh
  source "${SCRIPT_DIR}/../../build-scripts/lib.sh"
elif [[ -f "/tmp/lib.sh" ]]; then
  # Packer provisioner path: build-scripts/lib.sh was uploaded to /tmp/lib.sh
  # earlier in the image build, so source that copy instead.
  # shellcheck source=/tmp/lib.sh
  source "/tmp/lib.sh"
else
  # Fallback path: neither helper file is present, which can happen in ad hoc
  # runs outside the repo or Packer flow. Define maybe_sudo as a no-op wrapper
  # so the script still works when it is already running with sufficient
  # privileges and fails normally if elevated writes are actually required.
  maybe_sudo() {
    "$@"
  }
fi

export OPENFOLD_CACHE="${OPENFOLD_CACHE:-/opt/openfold3}"
export OPENFOLD_PARAMETER_DIR="${OPENFOLD_PARAMETER_DIR:-${OPENFOLD_CACHE}/checkpoints}"
export CC="${CC:-/usr/bin/gcc}"
export CXX="${CXX:-/usr/bin/g++}"

target_owner="${TARGET_USER:-$(id -un)}"
target_group="${TARGET_GROUP:-$(id -gn)}"

maybe_sudo mkdir -p "${OPENFOLD_CACHE}" "${OPENFOLD_PARAMETER_DIR}"
maybe_sudo chown -R "${target_owner}:${target_group}" "${OPENFOLD_CACHE}"
python3 "${SCRIPT_DIR}/setup_openfold_defaults.py"

if [[ "${build_env}" == "docker" ]]; then
  maybe_sudo chown -R root:root "${OPENFOLD_CACHE}"
else
  maybe_sudo chown -R "${target_owner}:${target_group}" "${OPENFOLD_CACHE}"
fi
maybe_sudo chmod -R a+rX "${OPENFOLD_CACHE}"

maybe_sudo tee /etc/profile.d/omsf-openfold3.sh >/dev/null <<EOF
export OPENFOLD_CACHE="${OPENFOLD_CACHE}"
export OPENFOLD_PARAMETER_DIR="${OPENFOLD_PARAMETER_DIR}"
export CC="${CC}"
export CXX="${CXX}"
EOF
maybe_sudo chmod 644 /etc/profile.d/omsf-openfold3.sh

echo "[openfold3-post-install] OpenFold assets prepared at ${OPENFOLD_CACHE}"
