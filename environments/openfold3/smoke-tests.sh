#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export OPENFOLD_CACHE="${OPENFOLD_CACHE:-/opt/openfold3}"
export OPENFOLD_PARAMETER_DIR="${OPENFOLD_PARAMETER_DIR:-${OPENFOLD_CACHE}/checkpoints}"

python -c "import openfold3; import lmdb"
python "${SCRIPT_DIR}/setup_openfold_defaults.py"
python -c "import lmdb; from openfold3.entry_points.experiment_runner import InferenceExperimentRunner"
run_openfold --help
