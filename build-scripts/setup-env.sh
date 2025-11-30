#!/usr/bin/env bash
set -euo pipefail

# micromamba root prefix
MAMBA_ROOT_PREFIX="/opt/micromamba"

if [[ -z "${ENVIRONMENT_DIRS:-}" ]]; then
  echo "[setup_env] ENVIRONMENT_DIRS must be set" >&2
  exit 1
fi

if [[ -z "${DEFAULT_ENVIRONMENT:-}" ]]; then
  echo "[setup_env] DEFAULT_ENVIRONMENT must be set" >&2
  exit 1
fi

read -r -a env_dirs <<< "${ENVIRONMENT_DIRS}"

if [[ ${#env_dirs[@]} -eq 0 ]]; then
  echo "[setup_env] ENVIRONMENT_DIRS must include at least one directory" >&2
  exit 1
fi

default_env_name="${DEFAULT_ENVIRONMENT}"

available_envs=()
default_env_found=false
for env_dir in "${env_dirs[@]}"; do
  [[ -z "${env_dir:-}" ]] && continue
  env_dir="${env_dir%/}"
  env_yaml="${env_dir}/environment.yaml"
  env_basename="$(basename "${env_dir}")"

  if [[ ! -f "${env_yaml}" ]]; then
    echo "[setup_env] Missing environment.yaml for '${env_basename}' at ${env_yaml}" >&2
    exit 1
  fi

  smoke_test="${env_dir}/smoke-tests.sh"
  if [[ ! -f "${smoke_test}" ]]; then
    echo "[setup_env] Missing smoke-tests.sh for '${env_basename}' at ${smoke_test}" >&2
    exit 1
  fi
  echo "[setup_env] Found smoke test script for '${env_basename}' at ${smoke_test}"

  echo "[setup_env] Creating micromamba environment '${env_basename}' from ${env_yaml}"

  sudo -u ubuntu env MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX" /usr/local/bin/micromamba env create -y -f "${env_yaml}"

  available_envs+=("${env_basename}")

  if [[ "${env_basename}" == "${default_env_name}" ]]; then
    default_env_found=true
  fi
done

if [[ "${default_env_found}" == false ]]; then
  echo "[setup_env] DEFAULT_ENVIRONMENT '${default_env_name}' not found in ENVIRONMENT_DIRS" >&2
  exit 1
fi

available_envs_str=""
if [[ ${#available_envs[@]} -gt 0 ]]; then
  printf -v available_envs_str '%s ' "${available_envs[@]}"
  available_envs_str="${available_envs_str% }"
fi

# Clean up caches to keep the image smaller
sudo -u ubuntu env MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX" /usr/local/bin/micromamba clean -a -y

echo "[setup_env] Installing profile hook in /etc/profile.d/micromamba.sh"

# Add a profile script so login shells can easily use micromamba
sudo tee /etc/profile.d/micromamba.sh >/dev/null <<EOF
export MAMBA_ROOT_PREFIX=/opt/micromamba
export MICROMAMBA_ENVIRONMENTS="${available_envs_str}"
export MICROMAMBA_DEFAULT_ENVIRONMENT="${default_env_name}"
if command -v micromamba >/dev/null 2>&1; then
  eval "\$(micromamba shell hook -s bash)"
fi

EOF

sudo chmod 644 /etc/profile.d/micromamba.sh

echo "[setup_env] Enabling auto-activation of '${default_env_name}' for ubuntu user"

# Ensure ubuntu's .profile exists and install the activation snippet for the configured environments
sudo -u ubuntu touch /home/ubuntu/.profile
sudo -u ubuntu sed -i '/# >>> micromamba auto-activation >>>/,/# <<< micromamba auto-activation <<</d' /home/ubuntu/.profile
sudo -u ubuntu tee -a /home/ubuntu/.profile >/dev/null <<'EOF'

# >>> micromamba auto-activation >>>
if [ -f /etc/profile.d/micromamba.sh ]; then
  . /etc/profile.d/micromamba.sh
fi
if command -v micromamba >/dev/null 2>&1 && [ -n "${MICROMAMBA_DEFAULT_ENVIRONMENT:-}" ]; then
  for __mamba_env in ${MICROMAMBA_ENVIRONMENTS}; do
    if [ "${__mamba_env}" = "${MICROMAMBA_DEFAULT_ENVIRONMENT}" ]; then
      micromamba activate "${MICROMAMBA_DEFAULT_ENVIRONMENT}"
      break
    fi
  done
  unset __mamba_env
fi
# <<< micromamba auto-activation <<<
EOF

echo "[setup_env] Done."
