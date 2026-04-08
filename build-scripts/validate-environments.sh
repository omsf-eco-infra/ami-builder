#!/usr/bin/env bash
set -euo pipefail

echo "[validate_env] Starting environment validation"

missing_envs="${MISSING_ENVIRONMENTS:-}"
missing_smoke="${MISSING_SMOKE:-}"
missing_full="${MISSING_FULL:-}"
env_dirs_var="${ENVIRONMENT_DIRS:-}"
pixi_manifest_path="${PIXI_MANIFEST_PATH:-}"
pixi_metadata_helper="${PIXI_METADATA_HELPER:-}"
env_dirs=()

fail=false
pixi_manifest_validation_ready=false
pixi_runtime_envs=()
pixi_missing_test_pairs=()

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

contains_word() {
  local needle="$1"
  shift

  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ -n "${pixi_manifest_path}" ]]; then
  if [[ ! -f "${pixi_manifest_path}" ]]; then
    echo "[validate_env] Pixi manifest not found at ${pixi_manifest_path}" >&2
    fail=true
  fi

  if [[ -z "${pixi_metadata_helper}" ]]; then
    echo "[validate_env] PIXI_METADATA_HELPER must be set when PIXI_MANIFEST_PATH is provided" >&2
    fail=true
  elif [[ ! -f "${pixi_metadata_helper}" ]]; then
    echo "[validate_env] Pixi metadata helper not found at ${pixi_metadata_helper}" >&2
    fail=true
  fi

  if [[ "${fail}" == false ]]; then
    python_bin=""
    if command -v python3 >/dev/null 2>&1; then
      python_bin="python3"
    elif command -v python >/dev/null 2>&1; then
      python_bin="python"
    else
      echo "[validate_env] Python is required to inspect ${pixi_manifest_path}" >&2
      fail=true
    fi

    if [[ -n "${python_bin}" ]]; then
      if ! pixi_metadata_shell="$("${python_bin}" "${pixi_metadata_helper}" --manifest "${pixi_manifest_path}" --format shell)"; then
        echo "[validate_env] Failed to read Pixi metadata from ${pixi_manifest_path}" >&2
        fail=true
      else
        # shellcheck disable=SC1090
        eval "${pixi_metadata_shell}"
        read -r -a pixi_runtime_envs <<< "${PIXI_RUNTIME_ENVIRONMENTS:-}"
        read -r -a pixi_missing_test_pairs <<< "${PIXI_MISSING_TEST_PAIRS:-}"
        pixi_manifest_validation_ready=true
      fi
    fi
  fi
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

  if [[ "${pixi_manifest_validation_ready}" == true ]]; then
    if ! contains_word "${env_name}" "${pixi_runtime_envs[@]}"; then
      echo "[validate_env] '${env_name}' is missing from the Pixi workspace manifest at ${pixi_manifest_path}" >&2
      fail=true
    fi

    if contains_word "${env_name}" "${pixi_missing_test_pairs[@]}"; then
      echo "[validate_env] '${env_name}' is missing paired test environment '${env_name}-test' in ${pixi_manifest_path}" >&2
      fail=true
    fi
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
