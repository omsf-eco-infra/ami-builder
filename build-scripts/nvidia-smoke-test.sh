set -euxo pipefail

echo "[nvidia module check] Checking DKMS + module availability"
dpkg -l | grep -E "nvidia-(dkms|driver|utils)" || {
  echo "NVIDIA driver packages not installed"; exit 1;
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
