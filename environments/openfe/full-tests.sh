#!/usr/bin/env bash
set -euo pipefail

OPEN_FILES_LIMIT="${OMSF_OPEN_FILES_LIMIT:-8192}"
if [[ "${OPEN_FILES_LIMIT}" =~ ^[0-9]+$ ]]; then
  ulimit -Sn "${OPEN_FILES_LIMIT}" || true
fi

echo "[openfe-full-tests] soft nofile=$(ulimit -Sn) hard nofile=$(ulimit -Hn)"
openfe test
