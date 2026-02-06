#!/usr/bin/env bash
set -euo pipefail

BUILD_ENV="${BUILD_ENV:-ami}"
if [[ "${BUILD_ENV}" == "docker" ]]; then
  TARGET_USER="root"
  USE_SUDO="false"
  MICROMAMBA_USE_PROFILE="false"
else
  TARGET_USER="ubuntu"
  USE_SUDO="true"
  MICROMAMBA_USE_PROFILE="true"
fi
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-/opt/micromamba}"
ENVIRONMENT_DIR_ROOT="${ENVIRONMENT_DIR_ROOT:-/tmp/environments}"

run_as_target_user() {
  if [[ "${TARGET_USER}" == "root" ]]; then
    "$@"
  elif [[ "${USE_SUDO}" == "true" ]]; then
    sudo -u "${TARGET_USER}" "$@"
  else
    "$@"
  fi
}

if [[ -z "${MICROMAMBA_ENV_NAME:-}" ]]; then
  echo "[smoke_test] MICROMAMBA_ENV_NAME must be set" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="${ENVIRONMENT_DIR_ROOT}/${MICROMAMBA_ENV_NAME}"
DEFAULT_SMOKE_TEST="${TEST_ROOT}/smoke-tests.sh"

SMOKE_TEST="${1:-$DEFAULT_SMOKE_TEST}"
if [[ "$SMOKE_TEST" != /* ]]; then
  SMOKE_TEST="$REPO_ROOT/$SMOKE_TEST"
fi

if [[ ! -f "$SMOKE_TEST" ]]; then
  echo "[smoke_test] Smoke test script '$SMOKE_TEST' not found" >&2
  exit 1
fi

echo "[smoke_test] Running smoke test '$SMOKE_TEST' in micromamba env '${MICROMAMBA_ENV_NAME}'"

run_as_target_user env \
  MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX" \
  MICROMAMBA_ENV_NAME="$MICROMAMBA_ENV_NAME" \
  MICROMAMBA_USE_PROFILE="$MICROMAMBA_USE_PROFILE" \
  SMOKE_TEST="$SMOKE_TEST" \
  bash <<'EOF'
set -euo pipefail
BASH_XTRACEFD=1  # Send `set -x` output to stdout (fd 1)

if [[ ! -f "$SMOKE_TEST" ]]; then
  echo "[smoke_test] Smoke test script '$SMOKE_TEST' not found" >&2
  exit 1
fi

export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX}"
if [[ "${MICROMAMBA_USE_PROFILE}" == "true" ]]; then
  if [[ ! -f /etc/profile.d/micromamba.sh ]]; then
    echo "[smoke_test] micromamba profile hook missing at /etc/profile.d/micromamba.sh" >&2
    exit 1
  fi
  # shellcheck source=/etc/profile.d/micromamba.sh
  source /etc/profile.d/micromamba.sh
else
  if command -v micromamba >/dev/null 2>&1; then
    eval "$(micromamba shell hook -s bash)"
  fi
fi

micromamba activate "$MICROMAMBA_ENV_NAME"

echo "[smoke_test] Activated micromamba env '$MICROMAMBA_ENV_NAME'"
set -x
# shellcheck source=/dev/null
source "$SMOKE_TEST"
set +x
echo "[smoke_test] Completed smoke test '$SMOKE_TEST'"
EOF

echo "[smoke_test] Smoke test finished."
