#!/usr/bin/env bash
set -euo pipefail

OPEN_FILES_LIMIT="${OMSF_OPEN_FILES_LIMIT:-8192}"
if [[ "${OPEN_FILES_LIMIT}" =~ ^[0-9]+$ ]]; then
  ulimit -Sn "${OPEN_FILES_LIMIT}" || true
fi

echo "[openfe-full-tests] soft nofile=$(ulimit -Sn) hard nofile=$(ulimit -Hn)"

if [[ "${OMSF_DEBUG_FDS:-0}" == "1" ]]; then
  openfe test &
  test_pid=$!

  cleanup() {
    if [[ -n "${sampler_pid:-}" ]]; then
      kill "${sampler_pid}" >/dev/null 2>&1 || true
      wait "${sampler_pid}" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup EXIT

  (
    peak=0
    while kill -0 "${test_pid}" >/dev/null 2>&1; do
      fd_count="$(find "/proc/${test_pid}/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
      if [[ "${fd_count}" =~ ^[0-9]+$ ]] && (( fd_count > peak )); then
        peak="${fd_count}"
        echo "[openfe-full-tests] pid=${test_pid} open_fds=${fd_count}"
      fi
      sleep 2
    done
  ) &
  sampler_pid=$!

  wait "${test_pid}"
else
  openfe test
fi
