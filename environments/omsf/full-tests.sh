#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

bash "${ENVIRONMENT_ROOT}/openfe/full-tests.sh"
#bash "${ENVIRONMENT_ROOT}/openpathsampling/full-tests.sh"
