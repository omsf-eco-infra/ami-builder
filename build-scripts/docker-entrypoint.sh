#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${MICROMAMBA_DEFAULT_ENVIRONMENT:-}" ]]; then
  if command -v micromamba >/dev/null 2>&1; then
    export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-/opt/micromamba}"
    eval "$(micromamba shell hook -s bash)"
    micromamba activate "${MICROMAMBA_DEFAULT_ENVIRONMENT}"
  fi
fi

if [[ $# -eq 0 ]]; then
  exec bash -l
fi

exec "$@"
