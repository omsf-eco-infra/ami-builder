#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_env="${BUILD_ENV:-ami}"

if [[ -f "${SCRIPT_DIR}/../../build-scripts/lib.sh" ]]; then
  # Local repo execution path: the script is being run from the checked-out
  # source tree, so we can source the shared helpers directly.
  # shellcheck source=build-scripts/lib.sh
  source "${SCRIPT_DIR}/../../build-scripts/lib.sh"
elif [[ -f "/tmp/lib.sh" ]]; then
  # Packer provisioner path: build-scripts/lib.sh was uploaded to /tmp/lib.sh
  # earlier in the image build, so source that copy instead.
  # shellcheck source=/tmp/lib.sh
  source "/tmp/lib.sh"
else
  # Fallback path: neither helper file is present, which can happen in ad hoc
  # runs outside the repo or Packer flow. Define maybe_sudo as a no-op wrapper
  # so the script still works when it is already running with sufficient
  # privileges and fails normally if elevated writes are actually required.
  maybe_sudo() {
    "$@"
  }
fi

export OPENFOLD_CACHE="${OPENFOLD_CACHE:-/opt/openfold3}"
export OPENFOLD_PARAMETER_DIR="${OPENFOLD_PARAMETER_DIR:-${OPENFOLD_CACHE}/checkpoints}"
export CC="${CC:-/usr/bin/gcc}"
export CXX="${CXX:-/usr/bin/g++}"

if [[ -z "${CONDA_PREFIX:-}" ]]; then
  echo "[openfold3-post-install] CONDA_PREFIX must be set by the pixi environment" >&2
  exit 1
fi

# CUDA architecture list, not an EC2 instance-type list. Default targets AWS g5
# A10G/Ampere GPUs; add future compute capabilities here or via Packer vars.
export OPENFOLD_CUDA_ARCH_LIST="${OPENFOLD_CUDA_ARCH_LIST:-8.6}"
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-${OPENFOLD_CUDA_ARCH_LIST}}"
export DS_IGNORE_CUDA_DETECTION="${DS_IGNORE_CUDA_DETECTION:-TRUE}"
export CUDA_HOME="${CUDA_HOME:-${CONDA_PREFIX}}"
export LIBRARY_PATH="${CONDA_PREFIX}/lib${LIBRARY_PATH:+:${LIBRARY_PATH}}"
export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export TORCH_EXTENSIONS_DIR="${TORCH_EXTENSIONS_DIR:-${OPENFOLD_CACHE}/torch_extensions}"

resolve_cutlass_path() {
  python3 - <<'PY'
from pathlib import Path

try:
    import cutlass_library
except Exception:
    print("DS_USE_CUTLASS_PYTHON_BINDINGS")
    raise SystemExit(0)

candidate = Path(cutlass_library.__file__).resolve().parent / "source"
if candidate.exists():
    print(candidate)
else:
    print("DS_USE_CUTLASS_PYTHON_BINDINGS")
PY
}

export CUTLASS_PATH="${CUTLASS_PATH:-$(resolve_cutlass_path)}"

target_owner="${TARGET_USER:-$(id -un)}"
target_group="${TARGET_GROUP:-$(id -gn)}"

precompile_openfold_kernels() {
  echo "[openfold3-post-install] Precompiling DeepSpeed Evoformer kernels for CUDA arch list: ${TORCH_CUDA_ARCH_LIST}"
  python3 - <<'PY'
from pathlib import Path
import os

from deepspeed.ops.op_builder import EvoformerAttnBuilder

extensions_dir = Path(os.environ["TORCH_EXTENSIONS_DIR"])
extensions_dir.mkdir(parents=True, exist_ok=True)

builder = EvoformerAttnBuilder()
builder.load(verbose=True)

compiled_artifacts = sorted(extensions_dir.rglob("*.so"))
if not compiled_artifacts:
    raise SystemExit(
        f"No compiled DeepSpeed extension artifacts found under {extensions_dir}"
    )

print("[openfold3-post-install] Compiled extension artifacts:")
for artifact in compiled_artifacts:
    print(f"  {artifact}")
PY
}

maybe_sudo mkdir -p "${OPENFOLD_CACHE}" "${OPENFOLD_PARAMETER_DIR}" "${TORCH_EXTENSIONS_DIR}"
maybe_sudo chown -R "${target_owner}:${target_group}" "${OPENFOLD_CACHE}"
python3 "${SCRIPT_DIR}/setup_openfold_defaults.py"
precompile_openfold_kernels

if [[ "${build_env}" == "docker" ]]; then
  maybe_sudo chown -R root:root "${OPENFOLD_CACHE}"
else
  maybe_sudo chown -R "${target_owner}:${target_group}" "${OPENFOLD_CACHE}"
fi
maybe_sudo chmod -R a+rX "${OPENFOLD_CACHE}"

maybe_sudo tee /etc/profile.d/omsf-openfold3.sh >/dev/null <<EOF
export OPENFOLD_CACHE="${OPENFOLD_CACHE}"
export OPENFOLD_PARAMETER_DIR="${OPENFOLD_PARAMETER_DIR}"
export CC="${CC}"
export CXX="${CXX}"
export OPENFOLD_CUDA_ARCH_LIST="\${OPENFOLD_CUDA_ARCH_LIST:-${OPENFOLD_CUDA_ARCH_LIST}}"
export TORCH_CUDA_ARCH_LIST="\${TORCH_CUDA_ARCH_LIST:-\${OPENFOLD_CUDA_ARCH_LIST}}"
export DS_IGNORE_CUDA_DETECTION="\${DS_IGNORE_CUDA_DETECTION:-${DS_IGNORE_CUDA_DETECTION}}"
if [ -z "\${CUTLASS_PATH:-}" ] || [ "\${CUTLASS_PATH}" = "DS_USE_CUTLASS_PYTHON_BINDINGS" ]; then
  export CUTLASS_PATH="${CUTLASS_PATH}"
fi
export CUDA_HOME="\${CUDA_HOME:-${CUDA_HOME}}"
export LIBRARY_PATH="${CONDA_PREFIX}/lib:\${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib:\${LD_LIBRARY_PATH:-}"
export TORCH_EXTENSIONS_DIR="\${TORCH_EXTENSIONS_DIR:-${TORCH_EXTENSIONS_DIR}}"
EOF
maybe_sudo chmod 644 /etc/profile.d/omsf-openfold3.sh

echo "[openfold3-post-install] OpenFold assets and precompiled kernels prepared at ${OPENFOLD_CACHE}"
