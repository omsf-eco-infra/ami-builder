#!/usr/bin/env bash

set -euo pipefail

build_singularity="${BUILD_SINGULARITY:-false}"
case "${build_singularity}" in
  1|true|yes|TRUE|YES)
    ;;
  0|false|no|FALSE|NO|"")
    echo "[singularity] SIF creation disabled; skipping"
    exit 0
    ;;
  *)
    echo "[singularity] BUILD_SINGULARITY must be true or false, got: ${build_singularity}" >&2
    exit 2
    ;;
esac

: "${DOCKER_IMAGE:?DOCKER_IMAGE must name the tagged Docker image to convert}"
: "${SINGULARITY_IMAGE:?SINGULARITY_IMAGE must be the output .sif path}"

if command -v apptainer >/dev/null 2>&1; then
  singularity_command="apptainer"
elif command -v singularity >/dev/null 2>&1; then
  singularity_command="singularity"
else
  echo "[singularity] Neither apptainer nor singularity is installed" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[singularity] docker is required to access the Packer-built image" >&2
  exit 1
fi

if ! docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
  echo "[singularity] Docker image is not available locally: ${DOCKER_IMAGE}" >&2
  exit 1
fi

output_directory="$(dirname -- "${SINGULARITY_IMAGE}")"
output_filename="$(basename -- "${SINGULARITY_IMAGE}")"
mkdir -p "${output_directory}"

temporary_image="${output_directory}/.${output_filename%.sif}.tmp.$$.sif"
cleanup() {
  rm -f -- "${temporary_image}"
}
trap cleanup EXIT

rm -f -- "${SINGULARITY_IMAGE}" "${SINGULARITY_IMAGE}.sha256"

echo "[singularity] Converting ${DOCKER_IMAGE} to ${SINGULARITY_IMAGE}"
"${singularity_command}" build \
  --disable-cache \
  --force \
  "${temporary_image}" \
  "docker-daemon:${DOCKER_IMAGE}"

"${singularity_command}" inspect "${temporary_image}" >/dev/null
mv -- "${temporary_image}" "${SINGULARITY_IMAGE}"

(
  cd "${output_directory}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${output_filename}" > "${output_filename}.sha256"
  else
    shasum -a 256 "${output_filename}" > "${output_filename}.sha256"
  fi
)

echo "[singularity] Created ${SINGULARITY_IMAGE}"
