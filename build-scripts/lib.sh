#!/usr/bin/env bash
set -euo pipefail

BUILD_ENV="${BUILD_ENV:-ami}"
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-/opt/micromamba}"

if [[ "${BUILD_ENV}" == "docker" ]]; then
  TARGET_USER="root"
  TARGET_GROUP="root"
  USE_SUDO="false"
  AUTO_ACTIVATE_DEFAULT="false"
  MICROMAMBA_USE_PROFILE="false"
else
  TARGET_USER="ubuntu"
  TARGET_GROUP="ubuntu"
  USE_SUDO="true"
  AUTO_ACTIVATE_DEFAULT="true"
  MICROMAMBA_USE_PROFILE="true"
fi

maybe_sudo() {
  if [[ "${USE_SUDO}" == "true" && "$(id -u)" -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

run_as_target_user() {
  if [[ "${TARGET_USER}" == "root" ]]; then
    "$@"
  elif [[ "${USE_SUDO}" == "true" ]]; then
    sudo -u "${TARGET_USER}" "$@"
  else
    "$@"
  fi
}

resolve_target_home() {
  if [[ "${TARGET_USER}" == "root" ]]; then
    echo "/root"
    return
  fi
  local home_dir
  home_dir="$(getent passwd "${TARGET_USER}" | cut -d: -f6 || true)"
  if [[ -z "${home_dir}" ]]; then
    echo "/home/${TARGET_USER}"
  else
    echo "${home_dir}"
  fi
}
