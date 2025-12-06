#!/usr/bin/env bash
set -euo pipefail

echo "[validate_env] Starting environment validation"

missing_envs="${MISSING_ENVIRONMENTS:-}"
missing_smoke="${MISSING_SMOKE:-}"
missing_full="${MISSING_FULL:-}"
env_dirs_var="${ENVIRONMENT_DIRS:-}"
env_dirs=()

fail=false

if [[ -n "${missing_envs// }" ]]; then
  echo "[validate_env] Missing environment directories for: ${missing_envs}" >&2
  fail=true
fi

if [[ -n "${missing_smoke// }" ]]; then
  echo "[validate_env] Missing smoke-tests.sh for: ${missing_smoke}" >&2
  fail=true
fi

if [[ -n "${missing_full// }" ]]; then
  echo "[validate_env] Missing full-tests.sh for: ${missing_full}" >&2
  fail=true
fi

# Split ENVIRONMENT_DIRS on whitespace; handles repeated spaces gracefully.
if [[ -n "${env_dirs_var// }" ]]; then
  set -- ${env_dirs_var}
  env_dirs=("$@")
fi

if [[ ${#env_dirs[@]} -eq 0 ]]; then
  echo "[validate_env] ENVIRONMENT_DIRS is empty or whitespace-only" >&2
  fail=true
fi

for env_dir in "${env_dirs[@]}"; do
  if [[ -z "${env_dir}" ]]; then
    echo "[validate_env] Encountered empty environment directory entry" >&2
    fail=true
    continue
  fi

  env_dir=${env_dir%/}
  env_name=$(basename "${env_dir}")

  if [[ ! -d "${env_dir}" ]]; then
    echo "[validate_env] Environment directory '${env_dir}' does not exist" >&2
    fail=true
    continue
  fi

  if [[ ! -f "${env_dir}/environment.yaml" ]]; then
    echo "[validate_env] '${env_name}' is missing environment.yaml at ${env_dir}/environment.yaml" >&2
    fail=true
  fi

  if [[ ! -f "${env_dir}/smoke-tests.sh" ]]; then
    echo "[validate_env] '${env_name}' is missing smoke-tests.sh at ${env_dir}/smoke-tests.sh" >&2
    fail=true
  fi

  if [[ ! -f "${env_dir}/full-tests.sh" ]]; then
    echo "[validate_env] '${env_name}' is missing full-tests.sh at ${env_dir}/full-tests.sh" >&2
    fail=true
  fi
done

if [[ "${fail}" == true ]]; then
  echo "[validate_env] Environment validation failed" >&2
  exit 1
fi

echo "[validate_env] Environment validation succeeded"
