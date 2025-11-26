#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: launch_instance.sh --ami AMI_ID --instance-type TYPE --security-group SG_ID --iam-profile NAME_OR_ARN [options]

Required:
  --ami AMI_ID               AMI to launch.
  --instance-type TYPE       Instance type (e.g., t3.medium).
  --security-group SG_ID     Security group to attach (no SSH ingress for SSM).
  --iam-profile NAME|ARN     Instance profile name or ARN for SSM/logs perms.

Optional:
  --subnet SUBNET_ID         Subnet to place the instance in (defaults to account/VPC default).
  --tag Key=Value            Tag to apply (repeatable, applies to instance + root volume). Default: Purpose=ami-test.
  --key-name KEY_NAME        EC2 key pair name (enables SSH fallback and forces public IP association).
  --volume-size GB           Override root volume size (gp3, DeleteOnTermination=true).
  --wait-timeout SECONDS     Wait for instance-status-ok (default: 900).
  --region REGION            AWS region override.
  --profile PROFILE          AWS CLI profile to use.
  --user-data-file PATH      Optional user data file (passed as file://).
  -h, --help                 Show this help text.

Outputs the InstanceId on stdout after the status checks pass.
USAGE
}

fail() {
  echo "[launch_instance] $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' not found in PATH"
}

AWS_REGION_OPT=()
AWS_PROFILE_OPT=()
AMI_ID=""
INSTANCE_TYPE=""
SUBNET_ID=""
SECURITY_GROUP_ID=""
IAM_PROFILE=""
KEY_NAME=""
ROOT_VOL_SIZE=""
WAIT_TIMEOUT=900
USER_DATA_FILE=""
TAGS=("Purpose=ami-test")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ami) AMI_ID="${2:-}"; shift 2;;
    --instance-type) INSTANCE_TYPE="${2:-}"; shift 2;;
    --subnet) SUBNET_ID="${2:-}"; shift 2;;
    --security-group|--sg) SECURITY_GROUP_ID="${2:-}"; shift 2;;
    --iam-profile) IAM_PROFILE="${2:-}"; shift 2;;
    --tag) TAGS+=("${2:-}"); shift 2;;
    --key-name) KEY_NAME="${2:-}"; shift 2;;
    --volume-size) ROOT_VOL_SIZE="${2:-}"; shift 2;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2;;
    --region) AWS_REGION_OPT=(--region "${2:-}"); shift 2;;
    --profile) AWS_PROFILE_OPT=(--profile "${2:-}"); shift 2;;
    --user-data-file) USER_DATA_FILE="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

require aws

[[ -n "$AMI_ID" ]] || fail "--ami is required"
[[ -n "$INSTANCE_TYPE" ]] || fail "--instance-type is required"
[[ -n "$SECURITY_GROUP_ID" ]] || fail "--security-group is required"
[[ -n "$IAM_PROFILE" ]] || fail "--iam-profile is required"

if [[ -n "$USER_DATA_FILE" && ! -f "$USER_DATA_FILE" ]]; then
  fail "User data file '$USER_DATA_FILE' not found"
fi

build_tag_spec() {
  local resource_type="$1"
  local first=1
  local tag_str=""
  for tag in "${TAGS[@]}"; do
    [[ "$tag" == *=* ]] || fail "Tag must be Key=Value: '$tag'"
    local key="${tag%%=*}"
    local value="${tag#*=}"
    if (( first )); then
      tag_str="{Key=${key},Value=${value}}"
      first=0
    else
      tag_str="${tag_str},{Key=${key},Value=${value}}"
    fi
  done
  printf "ResourceType=%s,Tags=[%s]" "$resource_type" "$tag_str"
}

iam_profile_arg() {
  if [[ "$IAM_PROFILE" == arn:aws:*:instance-profile/* ]]; then
    printf "Arn=%s" "$IAM_PROFILE"
  else
    printf "Name=%s" "$IAM_PROFILE"
  fi
}

TAG_SPEC_INSTANCE=$(build_tag_spec "instance")
TAG_SPEC_VOLUME=$(build_tag_spec "volume")

RUN_ARGS=(
  --image-id "$AMI_ID"
  --instance-type "$INSTANCE_TYPE"
  --security-group-ids "$SECURITY_GROUP_ID"
  --iam-instance-profile "$(iam_profile_arg)"
  --tag-specifications "$TAG_SPEC_INSTANCE" "$TAG_SPEC_VOLUME"
  --output json
)

if [[ -n "$SUBNET_ID" ]]; then
  RUN_ARGS+=(--subnet-id "$SUBNET_ID")
fi

if [[ -n "$KEY_NAME" ]]; then
  RUN_ARGS+=(--key-name "$KEY_NAME" --associate-public-ip-address)
fi

if [[ -n "$ROOT_VOL_SIZE" ]]; then
  RUN_ARGS+=(--block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${ROOT_VOL_SIZE},VolumeType=gp3,DeleteOnTermination=true}")
fi

if [[ -n "$USER_DATA_FILE" ]]; then
  RUN_ARGS+=(--user-data "file://${USER_DATA_FILE}")
fi

echo "[launch_instance] Starting instance from $AMI_ID ..."
INSTANCE_ID=$(aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" ec2 run-instances "${RUN_ARGS[@]}" --query 'Instances[0].InstanceId' --output text)

[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] || fail "Failed to obtain InstanceId from run-instances output"
echo "[launch_instance] InstanceId: $INSTANCE_ID"

deadline=$((SECONDS + WAIT_TIMEOUT))
echo "[launch_instance] Waiting for instance-status-ok (timeout: ${WAIT_TIMEOUT}s)..."
while (( SECONDS < deadline )); do
  INSTANCE_STATUS=$(aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" ec2 describe-instance-status --instance-ids "$INSTANCE_ID" --query 'InstanceStatuses[0].InstanceStatus.Status' --output text 2>/dev/null || true)
  SYSTEM_STATUS=$(aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" ec2 describe-instance-status --instance-ids "$INSTANCE_ID" --query 'InstanceStatuses[0].SystemStatus.Status' --output text 2>/dev/null || true)
  STATE=$(aws "${AWS_REGION_OPT[@]}" "${AWS_PROFILE_OPT[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || true)

  if [[ "$STATE" == "terminated" || "$STATE" == "shutting-down" ]]; then
    fail "Instance entered unexpected state '$STATE' while waiting"
  fi

  if [[ "$INSTANCE_STATUS" == "ok" && "$SYSTEM_STATUS" == "ok" ]]; then
    echo "[launch_instance] Instance passed status checks."
    echo "$INSTANCE_ID"
    exit 0
  fi

  sleep 10
done

fail "Timed out after ${WAIT_TIMEOUT}s waiting for instance-status-ok for $INSTANCE_ID"
