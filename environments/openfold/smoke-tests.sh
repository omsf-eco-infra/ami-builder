#!/usr/bin/env bash
set -euo pipefail

shopt -s nullglob

OPENFOLD_CACHE="${OPENFOLD_CACHE:-$HOME/.openfold3}"
OPENFOLD_CHECKPOINT_DIR="${OPENFOLD_CHECKPOINT_DIR:-$OPENFOLD_CACHE}"
OPENFOLD_CHECKPOINT_ROOT_FILE="${OPENFOLD_CACHE}/ckpt_root"
OPENFOLD_DEFAULT_CHECKPOINT_NAME="${OPENFOLD_DEFAULT_CHECKPOINT_NAME:-openfold3-p2-155k}"
OPENFOLD_DEFAULT_CHECKPOINT_FILE="${OPENFOLD_DEFAULT_CHECKPOINT_FILE:-of3-p2-155k.pt}"
OPENFOLD_CHECKPOINT_URL="${OPENFOLD_CHECKPOINT_URL:-https://openfold3-data.s3.amazonaws.com/openfold3-parameters/${OPENFOLD_DEFAULT_CHECKPOINT_FILE}}"
OPENFOLD_CCD_FILE="${OPENFOLD_CCD_FILE:-components.bcif}"
OPENFOLD_CCD_URL="${OPENFOLD_CCD_URL:-https://openfold3-data.s3.amazonaws.com/${OPENFOLD_CCD_FILE}}"

download_file() {
  local url="$1"
  local destination="$2"
  local temp_file="${destination}.tmp"

  mkdir -p "$(dirname "${destination}")"

  if command -v curl >/dev/null 2>&1; then
    curl \
      --fail \
      --location \
      --retry 5 \
      --retry-delay 5 \
      --output "${temp_file}" \
      "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${temp_file}" "${url}"
  else
    echo "[openfold-smoke] curl or wget is required to download ${url}" >&2
    return 1
  fi

  mv "${temp_file}" "${destination}"
}

resolve_biotite_ccd_path() {
  if [[ -z "${CONDA_PREFIX:-}" ]]; then
    echo "[openfold-smoke] CONDA_PREFIX is not set; cannot locate Biotite CCD path" >&2
    return 1
  fi

  local candidates=(
    "${CONDA_PREFIX}"/lib/python*/site-packages/biotite/structure/info/"${OPENFOLD_CCD_FILE}"
  )
  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "[openfold-smoke] Could not find Biotite CCD destination under ${CONDA_PREFIX}" >&2
    return 1
  fi

  printf '%s\n' "${candidates[0]}"
}

export OPENFOLD_CACHE
mkdir -p "${OPENFOLD_CACHE}" "${OPENFOLD_CHECKPOINT_DIR}"
printf '%s\n' "${OPENFOLD_CHECKPOINT_DIR}" > "${OPENFOLD_CHECKPOINT_ROOT_FILE}"

checkpoint_path="${OPENFOLD_CHECKPOINT_DIR}/${OPENFOLD_DEFAULT_CHECKPOINT_FILE}"
if [[ -s "${checkpoint_path}" ]]; then
  echo "[openfold-smoke] Using existing ${OPENFOLD_DEFAULT_CHECKPOINT_NAME} checkpoint at ${checkpoint_path}"
else
  echo "[openfold-smoke] Downloading ${OPENFOLD_DEFAULT_CHECKPOINT_NAME} checkpoint to ${checkpoint_path}"
  download_file "${OPENFOLD_CHECKPOINT_URL}" "${checkpoint_path}"
fi

biotite_ccd_path="$(resolve_biotite_ccd_path)"
if [[ -s "${biotite_ccd_path}" ]]; then
  echo "[openfold-smoke] Using existing Biotite CCD at ${biotite_ccd_path}"
else
  echo "[openfold-smoke] Downloading Biotite CCD to ${biotite_ccd_path}"
  download_file "${OPENFOLD_CCD_URL}" "${biotite_ccd_path}"
fi

run_openfold --help
