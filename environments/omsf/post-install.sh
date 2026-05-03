#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENFOLD_POST_INSTALL="${SCRIPT_DIR}/../openfold3/post-install.sh"

if [[ ! -f "${OPENFOLD_POST_INSTALL}" ]]; then
  echo "[omsf-post-install] Missing OpenFold post-install helper at ${OPENFOLD_POST_INSTALL}" >&2
  exit 1
fi

bash "${OPENFOLD_POST_INSTALL}"
