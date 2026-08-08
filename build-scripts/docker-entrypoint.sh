#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${PIXI_DEFAULT_ENVIRONMENT:-}" ]]; then
  workspace="${OMSF_PIXI_WORKSPACE:-${HOME}}"
  if [[ -f "${workspace}/pixi.toml" ]]; then
    activation_script="$(pixi shell-hook -m "${workspace}" -e "${PIXI_DEFAULT_ENVIRONMENT}" --shell bash --as-is --no-completions)"
    eval "${activation_script}"
  fi
fi

if [[ $# -eq 0 ]]; then
  exec bash -l
fi

exec "$@"
