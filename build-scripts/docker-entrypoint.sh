#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/profile.d/omsf-openfold3.sh ]]; then
  # shellcheck source=/etc/profile.d/omsf-openfold3.sh
  source /etc/profile.d/omsf-openfold3.sh
fi

if [[ -n "${PIXI_DEFAULT_ENVIRONMENT:-}" ]]; then
  workspace="${OMSF_PIXI_WORKSPACE:-${HOME}}"
  if [[ -f "${workspace}/pixi.toml" ]]; then
    eval "$(pixi shell-hook -m "${workspace}" -e "${PIXI_DEFAULT_ENVIRONMENT}" --shell bash --frozen --no-completions)"
  fi
fi

if [[ $# -eq 0 ]]; then
  exec bash -l
fi

exec "$@"
