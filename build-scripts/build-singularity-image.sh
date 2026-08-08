#!/usr/bin/env bash
set -euo pipefail

: "${DOCKER_IMAGE:?DOCKER_IMAGE must identify the Docker image to convert}"
: "${SIF_IMAGE:?SIF_IMAGE must identify the destination OCI artifact}"
: "${SIF_OUTPUT:?SIF_OUTPUT must be the local .sif output path}"

if ! command -v apptainer >/dev/null 2>&1; then
  echo "[sif] apptainer is required" >&2
  exit 1
fi

output_directory="$(dirname -- "${SIF_OUTPUT}")"
output_filename="$(basename -- "${SIF_OUTPUT}")"
temporary_image="${output_directory}/.${output_filename%.sif}.tmp.$$.sif"

mkdir -p "${output_directory}"
if [[ -n "${APPTAINER_TMPDIR:-}" ]]; then
  mkdir -p "${APPTAINER_TMPDIR}"
fi
cleanup() {
  rm -f -- "${temporary_image}"
}
trap cleanup EXIT

rm -f -- "${SIF_OUTPUT}"

echo "[sif] Filesystem capacity before conversion"
df -h "${APPTAINER_TMPDIR:-${TMPDIR:-/tmp}}" "${output_directory}" || true

echo "[sif] Converting docker://${DOCKER_IMAGE} to ${SIF_OUTPUT}"
apptainer build \
  --disable-cache \
  --force \
  "${temporary_image}" \
  "docker://${DOCKER_IMAGE}"

mv -- "${temporary_image}" "${SIF_OUTPUT}"

echo "[sif] Publishing ${SIF_OUTPUT} to oras://${SIF_IMAGE}"
apptainer push "${SIF_OUTPUT}" "oras://${SIF_IMAGE}"

echo "[sif] Published oras://${SIF_IMAGE}"
