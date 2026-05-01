#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_env="${BUILD_ENV:-ami}"

export OPENFOLD_CACHE="${OPENFOLD_CACHE:-/opt/openfold3}"
export OPENFOLD_PARAMETER_DIR="${OPENFOLD_PARAMETER_DIR:-${OPENFOLD_CACHE}/checkpoints}"
export CC="${CC:-/usr/bin/gcc}"
export CXX="${CXX:-/usr/bin/g++}"

mkdir -p "${OPENFOLD_CACHE}" "${OPENFOLD_PARAMETER_DIR}"
python3 "${SCRIPT_DIR}/setup_openfold_defaults.py"

if [[ "${build_env}" == "docker" ]]; then
  chown -R root:root "${OPENFOLD_CACHE}"
else
  chown -R ubuntu:ubuntu "${OPENFOLD_CACHE}"
fi
chmod -R a+rX "${OPENFOLD_CACHE}"

cat >/etc/profile.d/omsf-openfold3.sh <<EOF
export OPENFOLD_CACHE="${OPENFOLD_CACHE}"
export OPENFOLD_PARAMETER_DIR="${OPENFOLD_PARAMETER_DIR}"
export CC="${CC}"
export CXX="${CXX}"
EOF
chmod 644 /etc/profile.d/omsf-openfold3.sh

echo "[openfold3-post-install] OpenFold assets prepared at ${OPENFOLD_CACHE}"
