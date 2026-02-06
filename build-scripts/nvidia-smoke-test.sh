#!/usr/bin/env bash
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=build-scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ "${BUILD_ENV}" == "docker" ]]; then
  echo "[nvidia docker check] Checking nvidia-smi availability"
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "nvidia-smi not found; skipping GPU checks in Docker mode"
    exit 0
  fi
  nvidia-smi -L || {
    echo "nvidia-smi failed; GPU runtime may be unavailable"; exit 1
  }
  exit 0
fi

echo "[nvidia module check] Checking DKMS + module availability"
dpkg -l | grep -E "nvidia-(dkms|driver|utils)" || {
  echo "NVIDIA driver packages not installed"; exit 1
}

# DKMS reports that the module was built
dkms status || true
if ! dkms status | grep -qi "nvidia.*installed"; then
  echo "NVIDIA DKMS module not marked as installed"; exit 1
fi

# Module metadata exists
if ! modinfo nvidia > /dev/null 2>&1; then
  echo "modinfo nvidia failed; module may not be built correctly"; exit 1
fi

# Best-effort load; don't fail if it doesn't stick
if ! sudo modprobe nvidia; then
  echo "modprobe nvidia failed; likely no GPU present (t3.*). Not treating as fatal."
fi

lsmod | grep -i nvidia || echo "nvidia module not loaded (expected on non-GPU instances)"
