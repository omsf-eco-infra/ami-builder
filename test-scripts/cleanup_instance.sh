#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: cleanup_instance.sh --instance INSTANCE_ID [options]

Required:
  --instance INSTANCE_ID       EC2 instance to terminate.

Optional:
  --delete-security-group SG   Security group to delete after termination.
  --wait-timeout SECONDS       How long to wait for instance-terminated (default: 600).
  --region REGION              AWS region override.
  --profile PROFILE            AWS CLI profile to use.
  -h, --help                   Show this help text.

Terminates the instance, waits for termination, then deletes the optional security group.
USAGE
}

fail() {
  echo "[cleanup_instance] $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' not found in PATH"
}

AWS_REGION_OPT=()
AWS_PROFILE_OPT=()
INSTANCE_ID=""
DELETE_SG=""
WAIT_TIMEOUT=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE_ID="${2:-}"; shift 2;;
    --delete-security-group) DELETE_SG="${2:-}"; shift 2;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2;;
    --region) AWS_REGION_OPT=(--region "${2:-}"); shift 2;;
    --profile) AWS_PROFILE_OPT=(--profile "${2:-}"); shift 2;;
    -h|--help) usage; exit 0;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

require aws
[[ -n "$INSTANCE_ID" ]] || fail "--instance is required"

echo "[cleanup_instance] Terminating $INSTANCE_ID ..."
aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null

deadline=$((SECONDS + WAIT_TIMEOUT))
echo "[cleanup_instance] Waiting for instance-terminated (timeout: ${WAIT_TIMEOUT}s)..."
while (( SECONDS < deadline )); do
  STATE=$(aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || true)
  if [[ "$STATE" == "terminated" ]]; then
    echo "[cleanup_instance] Instance terminated."
    break
  fi
  sleep 10
done

if [[ "$STATE" != "terminated" ]]; then
  fail "Timed out waiting for termination (last state: $STATE)"
fi

if [[ -n "$DELETE_SG" ]]; then
  echo "[cleanup_instance] Deleting security group $DELETE_SG ..."
  aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" ec2 delete-security-group --group-id "$DELETE_SG"
fi

echo "$INSTANCE_ID"
