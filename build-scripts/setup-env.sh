#!/usr/bin/env bash
set -euo pipefail

# micromamba root prefix
MAMBA_ROOT_PREFIX="/opt/micromamba"

if [[ -z "${MICROMAMBA_ENV_NAME:-}" ]]; then
  echo "[setup_env] MICROMAMBA_ENV_NAME must be set" >&2
  exit 1
fi

if [[ -z "${MICROMAMBA_PACKAGES+x}" ]]; then
  echo "[setup_env] MICROMAMBA_PACKAGES must be set" >&2
  exit 1
fi

packages="${MICROMAMBA_PACKAGES}"
read -r -a package_args <<< "$packages"

env_name="${MICROMAMBA_ENV_NAME}"

echo "[setup_env] Creating micromamba '${env_name}' env from conda-forge with packages: ${packages}"

# Create the environment as the ubuntu user
sudo -u ubuntu env MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX" /usr/local/bin/micromamba create -y \
  -n "${env_name}" \
  -c conda-forge \
  "${package_args[@]}"

# Clean up caches to keep the image smaller
sudo -u ubuntu env MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX" /usr/local/bin/micromamba clean -a -y

echo "[setup_env] Installing profile hook in /etc/profile.d/micromamba.sh"

# Add a profile script so login shells can easily use micromamba
sudo tee /etc/profile.d/micromamba.sh >/dev/null << 'EOF'
export MAMBA_ROOT_PREFIX=/opt/micromamba
if command -v micromamba >/dev/null 2>&1; then
  eval "$(micromamba shell hook -s bash)"
fi
EOF

sudo chmod 644 /etc/profile.d/micromamba.sh

echo "[setup_env] Enabling auto-activation of '${env_name}' for ubuntu user"

# Ensure ubuntu's .profile exists and append an activation snippet if not already present
sudo -u ubuntu touch /home/ubuntu/.profile
if ! sudo -u ubuntu grep -q 'micromamba auto-activation' /home/ubuntu/.profile; then
  sudo -u ubuntu tee -a /home/ubuntu/.profile >/dev/null << EOF

# >>> micromamba auto-activation >>>
if [ -f /etc/profile.d/micromamba.sh ]; then
  source /etc/profile.d/micromamba.sh
fi
if command -v micromamba >/dev/null 2>&1; then
  micromamba activate "${env_name}"
fi
# <<< micromamba auto-activation <<<
EOF
fi

echo "[setup_env] Done."
