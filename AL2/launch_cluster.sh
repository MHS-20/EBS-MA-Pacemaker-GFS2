#!/bin/bash
# =============================================================================
# GFS2 + Pacemaker Cluster Launcher
# Launches EC2 instances from a Launch Template and bootstraps the cluster.
#
# Prerequisites:
#   - AWS CLI v2 configured with sufficient permissions
#   - A Launch Template configured for Amazon Linux 2
#   - An IAM instance profile for fencing
#   - SSH key pair accessible locally
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — edit these before running
# =============================================================================

NODE_NUMBER=5
NODE_NAME_PREFIX="ma-host"
NODE_NAMES=()

for i in $(seq 1 "$NODE_NUMBER"); do
  NODE_NAMES+=("${NODE_NAME_PREFIX}-${i}")
done

LAUNCH_TEMPLATE_ID="lt-07be018138967ad1c"
LAUNCH_TEMPLATE_VERSION="\$Latest"
AMI_ID="ami-0ba84fc44e8b9291d" # AL2
REGION="eu-west-1"
KEY_NAME="muhamad-keypair"
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
SSH_USER="ec2-user"
CLUSTER_NAME="macluster"
GFS2_TABLE_NAME="macluster:sharedFS"
GFS2_JOURNALS=5
GFS2_SIZE="20G"
GFS2_DEVICE="/dev/nvme1n1"
GFS2_MOUNT="/sharedFS"
HACLUSTER_PASS="pass"
FENCING_IAM_PROFILE="ec2-fencing-test"

# =============================================================================
# STEP 1 — Launch instances from the Launch Template
# =============================================================================

echo "========================================"
echo " Launching instances..."
echo "========================================"

INSTANCE_IDS=()
for i in "${!NODE_NAMES[@]}"; do
  NODE="${NODE_NAMES[$i]}"
  echo "  Launching $NODE..."
  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${LAUNCH_TEMPLATE_VERSION}" \
    --count 1 \
    --image-id "$AMI_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NODE}}]" \
    --iam-instance-profile "Name=${FENCING_IAM_PROFILE}" \
    --query 'Instances[0].InstanceId' \
    --output text)
  INSTANCE_IDS+=("$INSTANCE_ID")
  echo "    → $NODE: $INSTANCE_ID"
done

echo ""
echo "Waiting for all instances to reach 'running' state..."
aws ec2 wait instance-running \
  --region "$REGION" \
  --instance-ids "${INSTANCE_IDS[@]}"
echo "All instances running."

# =============================================================================
# STEP 2 — Retrieve private IPs
# =============================================================================

echo ""
echo "Retrieving private IPs..."
PRIVATE_IPS=()
for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
  IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)
  PRIVATE_IPS+=("$IP")
done

echo ""
echo "========================================"
echo " Cluster Node Summary"
echo "========================================"
printf "%-12s %-22s %-22s\n" "Name" "Instance ID" "Private IP"
printf "%-12s %-22s %-22s\n" "----" "-----------" "----------"
for i in "${!NODE_NAMES[@]}"; do
  printf "%-12s %-22s %-22s\n" "${NODE_NAMES[$i]}" "${INSTANCE_IDS[$i]}" "${PRIVATE_IPS[$i]}"
done

# =============================================================================
# STEP 3 — Build dynamic config strings
# =============================================================================

# /etc/hosts block
HOSTS_BLOCK=""
for i in "${!NODE_NAMES[@]}"; do
  HOSTS_BLOCK+="${PRIVATE_IPS[$i]} ${NODE_NAMES[$i]}\n"
done

# pcs pcmk_host_map string
FENCING_MAP=""
for i in "${!NODE_NAMES[@]}"; do
  [[ $i -gt 0 ]] && FENCING_MAP+=";"
  FENCING_MAP+="${NODE_NAMES[$i]}:${INSTANCE_IDS[$i]}"
done

# Comma-separated node names for pcs cluster auth/setup
NODE_LIST=$(
  IFS=" "
  echo "${NODE_NAMES[*]}"
)

echo ""
echo "Fencing host map:"
echo "  $FENCING_MAP"
echo ""

# =============================================================================
# STEP 4 — Wait for SSH to be ready on all nodes
# =============================================================================

echo "Waiting for SSH to be available on all nodes..."
for i in "${!NODE_NAMES[@]}"; do
  IP="${PRIVATE_IPS[$i]}"
  NODE="${NODE_NAMES[$i]}"
  echo -n "  Waiting for $NODE ($IP)..."
  until ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    -o BatchMode=yes \
    "${SSH_USER}@${IP}" "echo ok" &>/dev/null; do
    echo -n "."
    sleep 5
  done
  echo " ready"
done

# =============================================================================
# STEP 5 — Helper: run command on all nodes (parallel)
# =============================================================================

run_on_all() {
  local CMD="$1"
  local PIDS=()
  local FAILED=0
  for i in "${!NODE_NAMES[@]}"; do
    local IP="${PRIVATE_IPS[$i]}"
    local NODE="${NODE_NAMES[$i]}"
    (
      echo "[$NODE] Running: ${CMD:0:60}..."
      ssh -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        "${SSH_USER}@${IP}" "sudo bash -s" <<< "$CMD" 2>&1 | sed "s/^/[$NODE] /"
    ) &
    PIDS+=($!)
  done
  for PID in "${PIDS[@]}"; do
    wait "$PID" || FAILED=1
  done
  if [[ $FAILED -eq 1 ]]; then
    echo "ERROR: Command failed on one or more nodes: $CMD" >&2
    exit 1
  fi
}

# Helper: run command on first node only
run_on_primary() {
  local CMD="$1"
  local IP="${PRIVATE_IPS[0]}"
  local NODE="${NODE_NAMES[0]}"
  echo "[$NODE (primary)] Running: ${CMD:0:60}..."
  ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    "${SSH_USER}@${IP}" "sudo bash -s" <<< "$CMD" 2>&1 | sed "s/^/[$NODE] /"
}

# =============================================================================
# STEP 6 — ALL NODES: system packages + /etc/hosts
# =============================================================================

echo ""
echo "========================================"
echo " [All nodes] Installing packages..."
echo "========================================"

run_on_all "yum update -y"
run_on_all "yum install pcs pacemaker lvm2-cluster gfs2-utils dlm -y"
run_on_all "systemctl enable --now pcsd.service"
run_on_all "systemctl enable corosync pacemaker"
run_on_all "echo 'hacluster:${HACLUSTER_PASS}' | chpasswd"
run_on_all "/sbin/lvmconf --enable-cluster"
run_on_all "mkdir -p ${GFS2_MOUNT}"

echo ""
echo "========================================"
echo " [All nodes] Updating /etc/hosts..."
echo "========================================"

run_on_all "printf '${HOSTS_BLOCK}' >> /etc/hosts"

# =============================================================================
# STEP 7 — ALL NODES: fence-agents + boto3 upgrade
# =============================================================================

echo ""
echo "========================================"
echo " [All nodes] Installing fence-agents..."
echo "========================================"

run_on_all "yum remove -y awscli || true"
run_on_all "yum remove -y python2 python2-pip python2-boto3 || true"
run_on_all "amazon-linux-extras install python3.8 -y"
run_on_all "yum install -y python38-devel libcurl-devel gcc openssl-devel"
run_on_all "yum install -y fence-agents-aws"
run_on_all "/usr/bin/python3.8 -m ensurepip --upgrade"
run_on_all "/usr/bin/python3.8 -m pip install 'urllib3<2.0' boto3 botocore requests pexpect pycurl certifi --upgrade"

# Install latest AWS CLI v2
run_on_all "curl -s 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip && cd /tmp && unzip -q awscliv2.zip && ./aws/install --update && rm -rf /tmp/awscliv2.zip /tmp/aws/"

echo ""
echo "========================================"
echo " [All nodes] Fixing fence_aws shebang..."
echo "========================================"

run_on_all "sed -i 's|#!/usr/bin/python|#!/usr/bin/python3.8|' /usr/sbin/fence_aws"
run_on_all "grep -q 'region_name' /usr/sbin/fence_aws || sed -i \"s/conn = boto3.resource('ec2')/conn = boto3.resource('ec2', region_name=options.get('--region'))/\" /usr/sbin/fence_aws"

# =============================================================================
# STEP 8 — ONE NODE ONLY: cluster auth + setup
# =============================================================================

echo ""
echo "========================================"
echo " [Primary only] Configuring cluster..."
echo "========================================"

run_on_primary "pcs cluster auth ${NODE_LIST} -u hacluster -p ${HACLUSTER_PASS}"
run_on_primary "pcs cluster setup --name ${CLUSTER_NAME} ${NODE_LIST}"
run_on_primary "pcs cluster start --all"

echo "Waiting for cluster to stabilize..."
sleep 30

# =============================================================================
# STEP 9 — ONE NODE ONLY: fencing
# =============================================================================

echo ""
echo "========================================"
echo " [Primary only] Configuring fencing..."
echo "========================================"

run_on_primary "pcs property set stonith-enabled=true"
run_on_primary "pcs property set stonith-action=off"
run_on_primary "pcs property set startup-fencing=true"
run_on_primary "pcs property set no-quorum-policy=stop"
run_on_primary "pcs property set stonith-timeout=600s"

run_on_primary "pcs stonith create clusterfence fence_aws \
    region=${REGION} \
    pcmk_host_map='${FENCING_MAP}' \
    power_timeout=600 \
    pcmk_off_timeout=600 \
    pcmk_reboot_timeout=480 \
    pcmk_reboot_retries=4 \
    power_wait=5"

# =============================================================================
# STEP 10 — ONE NODE ONLY: DLM + CLVM + GFS2
# =============================================================================

echo ""
echo "========================================"
echo " [Primary only] Creating cluster resources..."
echo "========================================"

run_on_primary "pcs resource create dlm ocf:pacemaker:controld op monitor interval=30s on-fail=fence clone interleave=true ordered=true"
run_on_primary "pcs resource create clvmd ocf:heartbeat:clvm op monitor interval=30s on-fail=fence clone interleave=true ordered=true"
run_on_primary "pcs constraint order start dlm-clone then clvmd-clone"
run_on_primary "pcs constraint colocation add clvmd-clone with dlm-clone"

echo "Waiting for DLM + CLVM to start on all nodes..."
sleep 20

run_on_primary "pvcreate ${GFS2_DEVICE}"
run_on_primary "vgcreate -Ay -cy clustervg ${GFS2_DEVICE}"
run_on_primary "lvcreate -L${GFS2_SIZE} -n clusterlv clustervg"
run_on_primary "vgchange -ay clustervg"
run_on_primary "mkfs.gfs2 -j${GFS2_JOURNALS} -p lock_dlm -t ${GFS2_TABLE_NAME} /dev/clustervg/clusterlv"

run_on_primary "pcs resource create clusterfs Filesystem \
    device='/dev/clustervg/clusterlv' \
    directory='${GFS2_MOUNT}' \
    fstype='gfs2' \
    options='noatime' \
    op monitor interval=10s on-fail=fence clone interleave=true"

run_on_primary "pcs constraint order start clvmd-clone then clusterfs-clone"
run_on_primary "pcs constraint colocation add clusterfs-clone with clvmd-clone"

# =============================================================================
# STEP 11 — Final status + summary
# =============================================================================

echo ""
echo "Waiting for GFS2 to mount on all nodes..."
sleep 30

echo ""
echo "========================================"
echo " Final cluster status"
echo "========================================"
ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  "${SSH_USER}@${PRIVATE_IPS[0]}" \
  "sudo pcs status"

echo ""
echo "========================================"
echo " DONE — Cluster Summary"
echo "========================================"
printf "%-12s %-22s %-22s\n" "Name" "Instance ID" "Private IP"
printf "%-12s %-22s %-22s\n" "----" "-----------" "----------"
for i in "${!NODE_NAMES[@]}"; do
  printf "%-12s %-22s %-22s\n" "${NODE_NAMES[$i]}" "${INSTANCE_IDS[$i]}" "${PRIVATE_IPS[$i]}"
done
echo ""
echo "Fencing map:"
echo "  $FENCING_MAP"
echo ""
echo "To verify fencing manually:"
echo "  sudo fence_aws -o list --region $REGION --verbose"
echo "  sudo pcs stonith show clusterfence"
