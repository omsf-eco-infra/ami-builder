#!/usr/bin/env bash
set -euo pipefail

echo "[setup_env] Creating micromamba 'openfe' env from conda-forge"

# micromamba root prefix
MAMBA_ROOT_PREFIX="/opt/micromamba"

# Create the environment as the ubuntu user
sudo -u ubuntu env MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX" /usr/local/bin/micromamba create -y \
  -n openfe \
  -c conda-forge \
  openfe

# Clean up caches to keep the image smaller
sudo -u ubuntu env MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX" /usr/local/bin/micromamba clean -a -y

echo "[setup_openfe_env] Installing profile hook in /etc/profile.d/micromamba.sh"

# Add a profile script so login shells can easily use micromamba
sudo tee /etc/profile.d/micromamba.sh >/dev/null << 'EOF'
export MAMBA_ROOT_PREFIX=/opt/micromamba
if command -v micromamba >/dev/null 2>&1; then
  eval "$(micromamba shell hook -s bash)"
fi
EOF

sudo chmod 644 /etc/profile.d/micromamba.sh

echo "[setup_env] Done."
