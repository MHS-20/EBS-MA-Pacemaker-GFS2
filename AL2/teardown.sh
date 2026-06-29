#!/bin/bash
set -euo pipefail

REGION="eu-west-1"
CLUSTER_NAME_PREFIX="ma-host"
BASTION_NAME="vpc-bastion"

echo "=== Finding cluster instances to terminate ==="
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME_PREFIX}-*" "Name=instance-state-name,Values=running,pending,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)

if [[ -n "$INSTANCE_IDS" ]]; then
  echo "Terminating: $INSTANCE_IDS"
  aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS
  echo "Waiting for termination..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS
  echo "All cluster instances terminated."
else
  echo "No running cluster instances found."
fi

echo ""
echo "=== Finding shared EBS volume ==="
VOLUME_ID=$(aws ec2 describe-volumes \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=gfs2-shared" \
  --query 'Volumes[0].VolumeId' \
  --output text)

if [[ "$VOLUME_ID" != "None" && -n "$VOLUME_ID" ]]; then
  echo "Deleting volume: $VOLUME_ID"
  # Force detach if still attached
  aws ec2 detach-volume --region "$REGION" --volume-id "$VOLUME_ID" --force 2>/dev/null || true
  sleep 5
  aws ec2 delete-volume --region "$REGION" --volume-id "$VOLUME_ID" && echo "Deleted $VOLUME_ID"
else
  echo "No shared GFS2 volume found."
fi

echo ""
echo "=== Remaining instances ==="
aws ec2 describe-instances --region "$REGION" --filters "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0]]' --output table
