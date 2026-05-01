#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_ROOT="${TMPDIR:-/tmp}/openfold3-smoke"
trap 'rm -rf "${SMOKE_ROOT}"' EXIT

export OPENFOLD_CACHE="${SMOKE_ROOT}/cache"
export OPENFOLD_PARAMETER_DIR="${SMOKE_ROOT}/checkpoints"

python -c "import openfold3; import lmdb"
python "${SCRIPT_DIR}/setup_openfold_defaults.py"
python -c "import lmdb; from openfold3.entry_points.experiment_runner import InferenceExperimentRunner"
run_openfold --help
