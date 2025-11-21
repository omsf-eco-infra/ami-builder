#!/usr/bin/env bash
set -euo pipefail

# This script assumes it's running as the "ubuntu" user with sudo available.

echo "[install_micromamba] Installing micromamba into /usr/local/bin and preparing /opt/micromamba"

# Download and install micromamba
tmpdir="$(mktemp -d)"
pushd "$tmpdir" >/dev/null

curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj bin/micromamba
sudo mv bin/micromamba /usr/local/bin/micromamba
sudo chmod 755 /usr/local/bin/micromamba

popd >/dev/null
rm -rf "$tmpdir"

# Create a root prefix for micromamba and give it to the ubuntu user
sudo mkdir -p /opt/micromamba
sudo chown ubuntu:ubuntu /opt/micromamba

echo "[install_micromamba] Done."
