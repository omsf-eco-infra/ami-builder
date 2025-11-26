#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: run_tests_ssm.sh --instance INSTANCE_ID --script PATH --log-group LOG_GROUP [options]

Required:
  --instance INSTANCE_ID        EC2 instance to target.
  --script PATH                 Test script to run (local path; sent inline).
  --log-group LOG_GROUP         CloudWatch Logs group for command output.

Optional:
  --env-cmd "CMD"               Command to run before the test (e.g., micromamba activation).
  --log-stream NAME             Log stream name to tail (use when you know the exact stream).
  --log-stream-prefix PREFIX    Log stream prefix to tail (default: command-id/INSTANCE/awsrunShellScript).
  --timeout SECONDS             SSM command timeout (default: 3600).
  --poll-interval SECONDS       Poll interval for SSM status (default: 5).
  --run-as-user USER            Run the remote script as USER (default: ubuntu).
  --no-tail                     Do not stream CloudWatch Logs while running.
  --comment TEXT                Optional SSM command comment.
  --region REGION               AWS region override.
  --profile PROFILE             AWS CLI profile to use.
  -h, --help                    Show this help text.

Exits with the remote script's exit code.
USAGE
}

fail() {
  echo "[run_tests_ssm] $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' not found in PATH"
}

AWS_REGION_OPT=()
AWS_PROFILE_OPT=()
INSTANCE_ID=""
TEST_SCRIPT=""
LOG_GROUP=""
ENV_CMD=""
LOG_STREAM=""
LOG_STREAM_PREFIX=""
LOG_TAIL_ARGS=()
LOG_TAIL_DESC=""
RUN_AS_USER="ubuntu"
TIMEOUT=3600
POLL_INTERVAL=5
TAIL_LOGS="true"
COMMENT="AMI test via SSM"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE_ID="${2:-}"; shift 2;;
    --script) TEST_SCRIPT="${2:-}"; shift 2;;
    --log-group) LOG_GROUP="${2:-}"; shift 2;;
    --env-cmd) ENV_CMD="${2:-}"; shift 2;;
    --log-stream) LOG_STREAM="${2:-}"; shift 2;;
    --log-stream-prefix) LOG_STREAM_PREFIX="${2:-}"; shift 2;;
    --timeout) TIMEOUT="${2:-}"; shift 2;;
    --poll-interval) POLL_INTERVAL="${2:-}"; shift 2;;
    --run-as-user) RUN_AS_USER="${2:-}"; shift 2;;
    --no-tail) TAIL_LOGS="false"; shift;;
    --comment) COMMENT="${2:-}"; shift 2;;
    --region) AWS_REGION_OPT=(--region "${2:-}"); shift 2;;
    --profile) AWS_PROFILE_OPT=(--profile "${2:-}"); shift 2;;
    -h|--help) usage; exit 0;;
    *) usage; fail "Unknown argument: $1";;
  esac
done

if [[ -z "$RUN_AS_USER" ]]; then
  fail "--run-as-user cannot be empty"
fi

if [[ ! "$RUN_AS_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  fail "--run-as-user must match ^[a-z_][a-z0-9_-]*$"
fi

require aws
require base64

PYTHON_BIN="python3"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  PYTHON_BIN="python"
fi
require "$PYTHON_BIN"

[[ -n "$INSTANCE_ID" ]] || fail "--instance is required"
[[ -n "$TEST_SCRIPT" ]] || fail "--script is required"
[[ -n "$LOG_GROUP" ]] || fail "--log-group is required"

if [[ "$TEST_SCRIPT" != /* ]]; then
  TEST_SCRIPT="$(cd "$(dirname "$TEST_SCRIPT")" && pwd)/$(basename "$TEST_SCRIPT")"
fi
[[ -f "$TEST_SCRIPT" ]] || fail "Test script '$TEST_SCRIPT' not found"

LOG_GROUP_EXISTS=$(aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP" \
  --query "length(logGroups[?logGroupName=='${LOG_GROUP}'])" \
  --output text 2>/dev/null || true)

if [[ "$LOG_GROUP_EXISTS" == "0" || -z "$LOG_GROUP_EXISTS" || "$LOG_GROUP_EXISTS" == "None" ]]; then
  fail "CloudWatch Logs group '$LOG_GROUP' not found or not accessible"
fi

REMOTE_SCRIPT="/tmp/ami-test-${INSTANCE_ID}-$(date +%s).sh"
RUNNER_SCRIPT="/tmp/ami-test-runner-${INSTANCE_ID}-$(date +%s).sh"
USER_SCRIPT="/tmp/ami-test-user-${INSTANCE_ID}-$(date +%s).sh"

SCRIPT_B64=$(base64 < "$TEST_SCRIPT" | tr -d '\n')
USER_CONTENT=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
#export PS1="${PS1:-}"
#if [[ -f ~/.bashrc ]]; then
#  # shellcheck disable=SC1090
#  source ~/.bashrc
#fi
${ENV_CMD:+$ENV_CMD
}
"$REMOTE_SCRIPT"
EOF
)
USER_B64=$(printf '%s' "$USER_CONTENT" | base64 | tr -d '\n')
RUNNER_TARGET_USER="$RUN_AS_USER"
RUNNER_TEMPLATE=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

RUN_AS_USER="__RUN_AS_USER__"
USER_SCRIPT="__USER_SCRIPT__"

if command -v sudo >/dev/null 2>&1; then
  if ! sudo --login --user "$RUN_AS_USER" -- bash -lc "$USER_SCRIPT"; then
    sudo su - "$RUN_AS_USER" -c "bash -lc \"$USER_SCRIPT\""
  fi
else
  sudo su - "$RUN_AS_USER" -c "bash -lc \"$USER_SCRIPT\"" || su - "$RUN_AS_USER" -c "bash -lc \"$USER_SCRIPT\""
fi
EOF
)
RUNNER_CONTENT="${RUNNER_TEMPLATE//__RUN_AS_USER__/$RUNNER_TARGET_USER}"
RUNNER_CONTENT="${RUNNER_CONTENT//__USER_SCRIPT__/$USER_SCRIPT}"
RUNNER_B64=$(printf '%s' "$RUNNER_CONTENT" | base64 | tr -d '\n')

CW_CONFIG="CloudWatchLogGroupName=${LOG_GROUP},CloudWatchOutputEnabled=true"

SSM_COMMANDS=(
  "set -eu"
  "printf '%s' \"$SCRIPT_B64\" | base64 --decode > \"$REMOTE_SCRIPT\""
  "chmod +x \"$REMOTE_SCRIPT\""
  "printf '%s' \"$USER_B64\" | base64 --decode > \"$USER_SCRIPT\""
  "chmod +x \"$USER_SCRIPT\""
  "printf '%s' \"$RUNNER_B64\" | base64 --decode > \"$RUNNER_SCRIPT\""
  "chmod +x \"$RUNNER_SCRIPT\""
  "\"$RUNNER_SCRIPT\""
)

PARAMS_FILE=$(mktemp)
cleanup() {
  rm -f "$PARAMS_FILE"
  if [[ -n "${TAIL_PID:-}" ]]; then
    kill "$TAIL_PID" >/dev/null 2>&1 || true
    wait "$TAIL_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

SSM_COMMANDS_ENV=$(printf '%s\n' "${SSM_COMMANDS[@]}")
SSM_COMMANDS="$SSM_COMMANDS_ENV" "$PYTHON_BIN" - <<'PY' > "$PARAMS_FILE"
import json, os
raw = os.environ.get("SSM_COMMANDS", "")
cmds = raw.splitlines()
print(json.dumps({"commands": cmds}))
PY

COMMAND_ID=$(aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$INSTANCE_ID" \
  --comment "$COMMENT" \
  --parameters "file://${PARAMS_FILE}" \
  --cloud-watch-output-config "$CW_CONFIG" \
  --timeout-seconds "$TIMEOUT" \
  --query 'Command.CommandId' \
  --output text)

[[ -n "$COMMAND_ID" && "$COMMAND_ID" != "None" ]] || fail "Failed to obtain CommandId from send-command output"
echo "[run_tests_ssm] CommandId: $COMMAND_ID"

if [[ "$TAIL_LOGS" == "true" ]]; then
  DEFAULT_PREFIX="${COMMAND_ID}/${INSTANCE_ID}"
  DEFAULT_STREAM="${DEFAULT_PREFIX}/awsrunShellScript"

  if [[ -n "$LOG_STREAM" ]]; then
    LOG_TAIL_ARGS=(--log-stream-names "$LOG_STREAM")
    LOG_TAIL_DESC="stream '${LOG_STREAM}'"
  elif [[ -n "$LOG_STREAM_PREFIX" ]]; then
    LOG_TAIL_ARGS=(--log-stream-name-prefix "$LOG_STREAM_PREFIX")
    LOG_TAIL_DESC="stream prefix '${LOG_STREAM_PREFIX}'"
  else
    LOG_TAIL_ARGS=(--log-stream-names "$DEFAULT_STREAM")
    LOG_TAIL_DESC="stream '${DEFAULT_STREAM}' (SSM-managed)"
  fi

  if [[ "${#LOG_TAIL_ARGS[@]}" -eq 0 ]]; then
    echo "[run_tests_ssm] No CloudWatch Logs stream or prefix determined; skipping tailing (set --log-stream or --log-stream-prefix)" >&2
    TAIL_LOGS="false"
  else
    LOG_TAIL_DESC="${LOG_TAIL_DESC:-configured selection}"
    echo "[run_tests_ssm] Streaming CloudWatch Logs from ${LOG_TAIL_DESC}"
    aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" logs tail "$LOG_GROUP" "${LOG_TAIL_ARGS[@]}" --since 5m --follow &
    TAIL_PID=$!
    sleep 2
    if ! kill -0 "$TAIL_PID" >/dev/null 2>&1; then
      if [[ -z "$LOG_STREAM" && -z "$LOG_STREAM_PREFIX" ]]; then
        echo "[run_tests_ssm] Log stream '${DEFAULT_STREAM}' not yet available; retrying with stream prefix '${DEFAULT_PREFIX}' (SSM-managed fallback)" >&2
        LOG_TAIL_ARGS=(--log-stream-name-prefix "$DEFAULT_PREFIX")
        LOG_TAIL_DESC="stream prefix '${DEFAULT_PREFIX}' (SSM-managed fallback)"
        aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" logs tail "$LOG_GROUP" "${LOG_TAIL_ARGS[@]}" --since 5m --follow &
        TAIL_PID=$!
        sleep 2
        if ! kill -0 "$TAIL_PID" >/dev/null 2>&1; then
          echo "[run_tests_ssm] Failed to start log tail for ${LOG_TAIL_DESC}; continuing without streaming" >&2
          TAIL_LOGS="false"
          TAIL_PID=""
        else
          echo "[run_tests_ssm] Streaming CloudWatch Logs from ${LOG_TAIL_DESC}"
        fi
      else
        echo "[run_tests_ssm] Failed to start log tail for ${LOG_TAIL_DESC}; continuing without streaming" >&2
        TAIL_LOGS="false"
        TAIL_PID=""
      fi
    fi
  fi
fi

deadline=$((SECONDS + TIMEOUT + 120))
EXIT_CODE=1
while :; do
  read -r STATUS RESP_CODE <<<"$(aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query '[Status,ResponseCode]' \
    --output text 2>/dev/null || echo "Pending -1")"

  case "$STATUS" in
    Success)
      EXIT_CODE=${RESP_CODE:-0}
      break
      ;;
    Cancelled|Failed|TimedOut|Undeliverable|Terminated)
      EXIT_CODE=${RESP_CODE:-1}
      echo "[run_tests_ssm] Command ended with status '$STATUS' (exit $EXIT_CODE)" >&2
      break
      ;;
    InProgress|Pending|Delayed|Cancelling)
      if (( SECONDS >= deadline )); then
        echo "[run_tests_ssm] Timed out waiting for command $COMMAND_ID" >&2
        EXIT_CODE=124
        break
      fi
      sleep "$POLL_INTERVAL"
      ;;
    *)
      echo "[run_tests_ssm] Unknown status '$STATUS', continuing to poll" >&2
      sleep "$POLL_INTERVAL"
      ;;
  esac
done

exit "$EXIT_CODE"
