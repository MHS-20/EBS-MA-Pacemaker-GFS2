#!/bin/bash
# =============================================================================
# GFS2 + Pacemaker Cluster Launcher (AL2023)
# Launches EC2 instances from a Launch Template and bootstraps the cluster.
# Differs from AL2: custom kernel, source builds, lvmlockd, pcs host auth.
#
# Prerequisites:
#   - AWS CLI v2 configured with sufficient permissions
#   - A Launch Template configured for Amazon Linux 2023
#   - An IAM instance profile for fencing
#   - SSH key pair accessible locally
#   - Pre-compiled kernel archive in S3 (build via SetUpAL2023.md)
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

AMI_ID="ami-05cbf8a8aa4e4b755"       # AL2023
INSTANCE_TYPE="m7i.large"
SUBNET_ID="subnet-6570782d"            # eu-west-1a (same AZ for multiattach)
SECURITY_GROUP_ID="sg-c56ee982"        # default VPC SG
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
KERNEL_S3_BUCKET="s3://muhamad-tirocinio-bucket-861507897222-eu-west-1-an"
KERNEL_VERSION="6.1.161"
KERNEL_FILE="kernel-${KERNEL_VERSION}-custom.tar.gz"

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
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NODE}}]" \
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
# STEP 2 — Retrieve IPs (public for SSH, private for cluster)
# =============================================================================

echo ""
echo "Retrieving IPs..."
PRIVATE_IPS=()
PUBLIC_IPS=()
for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
  PRIV=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)
  PUB=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
  PRIVATE_IPS+=("$PRIV")
  PUBLIC_IPS+=("$PUB")
done

echo ""
echo "========================================"
echo " Cluster Node Summary"
echo "========================================"
printf "%-12s %-22s %-22s %-16s\n" "Name" "Instance ID" "Private IP" "Public IP"
printf "%-12s %-22s %-22s %-16s\n" "----" "-----------" "----------" "---------"
for i in "${!NODE_NAMES[@]}"; do
  printf "%-12s %-22s %-22s %-16s\n" "${NODE_NAMES[$i]}" "${INSTANCE_IDS[$i]}" "${PRIVATE_IPS[$i]}" "${PUBLIC_IPS[$i]}"
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

# Space-separated node names for pcs commands
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
  IP="${PUBLIC_IPS[$i]}"
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
# STEP 5 — Helper functions
# =============================================================================

run_on_all() {
  local CMD="$1"
  local PIDS=()
  local FAILED=0
  for i in "${!NODE_NAMES[@]}"; do
    local IP="${PUBLIC_IPS[$i]}"
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

run_on_primary() {
  local CMD="$1"
  local IP="${PUBLIC_IPS[0]}"
  local NODE="${NODE_NAMES[0]}"
  echo "[$NODE (primary)] Running: ${CMD:0:60}..."
  ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    "${SSH_USER}@${IP}" "sudo bash -s" <<< "$CMD" 2>&1 | sed "s/^/[$NODE] /"
}

wait_for_ssh() {
  echo "Waiting for SSH to recover on all nodes after reboot..."
  for i in "${!NODE_NAMES[@]}"; do
    IP="${PUBLIC_IPS[$i]}"
    NODE="${NODE_NAMES[$i]}"
    echo -n "  Waiting for $NODE ($IP)..."
    until ssh -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      "${SSH_USER}@${IP}" "echo ok" &>/dev/null; do
      echo -n "."
      sleep 10
    done
    echo " ready"
  done
}

# =============================================================================
# STEP 6 — ALL NODES: system packages + /etc/hosts
# =============================================================================

echo ""
echo "========================================"
echo " [All nodes] Installing system packages..."
echo "========================================"

run_on_all "dnf update -y"
run_on_all "dnf groupinstall 'Development Tools' -y"
run_on_all "dnf install -y pcs pacemaker openssl-devel elfutils-libelf-devel bc flex bison perl ncurses-devel dwarves rsync wget curl git hmaccalc python3-devel perl-generators perl-ExtUtils-Embed libaio-devel autoconf automake libtool gettext zlib-devel bzip2-devel libblkid-devel libuuid-devel kernel-devel pkgconfig corosynclib-devel libqb-devel systemd-devel libxml2-devel pacemaker-libs-devel readline-devel device-mapper-devel device-mapper-event-devel"
run_on_all "systemctl enable --now pcsd.service"
run_on_all "systemctl enable corosync pacemaker"
run_on_all "echo 'hacluster:${HACLUSTER_PASS}' | chpasswd"
run_on_all "mkdir -p ${GFS2_MOUNT}"

echo ""
echo "========================================"
echo " [All nodes] Updating /etc/hosts..."
echo "========================================"

run_on_all "printf '${HOSTS_BLOCK}' >> /etc/hosts"

# =============================================================================
# STEP 7 — ALL NODES: download and install custom kernel from S3
# =============================================================================

echo ""
echo "========================================"
echo " [All nodes] Installing custom kernel..."
echo "========================================"

run_on_all "aws s3 cp ${KERNEL_S3_BUCKET}/${KERNEL_FILE} /tmp/${KERNEL_FILE}"
run_on_all "tar -xzf /tmp/${KERNEL_FILE} -C /"
run_on_all "grubby --add-kernel=/boot/vmlinuz-${KERNEL_VERSION}-custom --initrd=/boot/initramfs-${KERNEL_VERSION}-custom.img --title='Linux ${KERNEL_VERSION} custom (GFS2+DLM)' --copy-default --make-default || grubby --add-kernel=/boot/vmlinuz-${KERNEL_VERSION}-custom --initrd=/boot/initramfs-${KERNEL_VERSION}-custom.img --title='Linux ${KERNEL_VERSION} custom' --copy-default --make-default"

echo ""
echo "========================================"
echo " Rebooting all nodes to load new kernel..."
echo "========================================"

# Reboot all nodes in parallel (capture PIDs but don't exit on SSH disconnect)
REBOOT_PIDS=()
for i in "${!NODE_NAMES[@]}"; do
  IP="${PUBLIC_IPS[$i]}"
  NODE="${NODE_NAMES[$i]}"
  (
    ssh -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      "${SSH_USER}@${IP}" "sudo reboot" 2>/dev/null || true
  ) &
  REBOOT_PIDS+=($!)
done

echo "Waiting for all nodes to reboot..."
sleep 30

wait_for_ssh

# Verify new kernel
echo ""
echo "========================================"
echo " [All nodes] Verifying kernel..."
echo "========================================"

run_on_all "uname -r | grep -q ${KERNEL_VERSION} || (echo 'ERROR: Kernel mismatch'; exit 1)"
run_on_all "modprobe gfs2 && modprobe dlm && lsmod | grep -E 'gfs2|dlm'"

# =============================================================================
# STEP 8 — ALL NODES: build gfs2-utils from source
# =============================================================================

echo ""
echo "========================================"
echo " [All nodes] Building gfs2-utils..."
echo "========================================"

run_on_all "cd /tmp && git clone https://pagure.io/gfs2-utils.git && cd /tmp/gfs2-utils && ./autogen.sh && ./configure --prefix=/usr --sbindir=/usr/sbin --sysconfdir=/etc && make -j\$(nproc) && make install"

# =============================================================================
# STEP 9 — ALL NODES: build dlm from source
# =============================================================================

echo ""
echo "========================================"
echo " [All nodes] Building dlm..."
echo "========================================"

run_on_all "cd /tmp && git clone https://pagure.io/dlm.git && cd /tmp/dlm && ./configure && make -j\$(nproc) && make install && ldconfig"

# =============================================================================
# STEP 10 — ALL NODES: build lvm2 from source
# =============================================================================

echo ""
echo "========================================"
echo " [All nodes] Building lvm2..."
echo "========================================"

run_on_all "cd /tmp && git clone https://gitlab.com/lvmteam/lvm2.git && cd /tmp/lvm2 && ./configure --enable-lvmlockd-dlm --disable-lvmlockd-sanlock --enable-cluster --enable-cmocks --prefix=/usr --sbindir=/usr/sbin --sysconfdir=/etc --localstatedir=/var && make -j\$(nproc) && rm -f /usr/sbin/lvmlockd /usr/sbin/lvmlockctl && make install && ldconfig"

# =============================================================================
# STEP 11 — ALL NODES: configure lvmlockd + DLM modules
# =============================================================================

echo ""
echo "========================================"
echo " [All nodes] Configuring lvmlockd and DLM..."
echo "========================================"

# Create lvmlockd systemd service
run_on_all "cat > /etc/systemd/system/lvmlockd.service << 'SERVICEOF'
[Unit]
Description=LVM lock daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/lvmlockd -f
ExecStop=/usr/sbin/lvmlockd --kill
Restart=no

[Install]
WantedBy=multi-user.target
SERVICEOF"
run_on_all "systemctl daemon-reload"
run_on_all "sed -i 's/use_lvmlockd = 0/use_lvmlockd = 1/' /etc/lvm/lvm.conf"

# Mount configfs and load modules
run_on_all "mount -t configfs none /sys/kernel/config 2>/dev/null || true"
run_on_all "modprobe dlm && modprobe gfs2"
run_on_all "echo 'configfs /sys/kernel/config configfs defaults 0 0' >> /etc/fstab"

# Create modules-load config
run_on_all "cat > /etc/modules-load.d/cluster.conf << 'EOF'
dlm
gfs2
EOF"

# Create DLM device nodes and udev rules
run_on_all "
MINOR=\$(cat /proc/misc 2>/dev/null | grep dlm-control | awk '{print \$1}')
if [ -n \"\$MINOR\" ]; then
  mkdir -p /dev/misc
  mknod /dev/misc/dlm-control c 10 \$MINOR 2>/dev/null || true
  chmod 600 /dev/misc/dlm-control
fi
MINOR=\$(cat /proc/misc 2>/dev/null | grep 'dlm-monitor' | awk '{print \$1}')
if [ -n \"\$MINOR\" ]; then
  mkdir -p /dev/misc
  mknod /dev/misc/dlm-monitor c 10 \$MINOR 2>/dev/null || true
  chmod 600 /dev/misc/dlm-monitor
fi"

run_on_all "cat > /etc/udev/rules.d/99-dlm.rules << 'EOF'
KERNEL==\"dlm-control\", SUBSYSTEM==\"misc\", MODE=\"0600\"
KERNEL==\"dlm-monitor\", SUBSYSTEM==\"misc\", MODE=\"0600\"
EOF"
run_on_all "udevadm control --reload-rules && udevadm trigger --subsystem-match=misc && udevadm settle"

# =============================================================================
# STEP 12 — ALL NODES: build and install fence-agents from source
# =============================================================================

echo ""
echo "========================================"
echo " [All nodes] Building fence-agents..."
echo "========================================"

run_on_all "dnf install -y python3-boto3 python3-botocore python3-requests python3-pexpect python3-pycurl python3-certifi python3-urllib3 libcurl-devel openssl-devel"
run_on_all "cd /tmp && git clone https://github.com/ClusterLabs/fence-agents.git && cd /tmp/fence-agents && ./autogen.sh && ./configure --with-agents=aws && make -j\$(nproc) && make install"

# =============================================================================
# STEP 13 — ONE NODE ONLY: cluster auth + setup
# =============================================================================

echo ""
echo "========================================"
echo " [Primary only] Configuring cluster..."
echo "========================================"

run_on_primary "pcs host auth ${NODE_LIST} -u hacluster -p ${HACLUSTER_PASS}"
run_on_primary "pcs cluster setup ${CLUSTER_NAME} ${NODE_LIST}"
run_on_primary "pcs cluster start --all"
run_on_primary "pcs cluster enable --all"

echo "Waiting for cluster to stabilize..."
sleep 30

# =============================================================================
# STEP 14 — ONE NODE ONLY: fencing
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
    power_timeout=240 \
    pcmk_off_timeout=600 \
    pcmk_reboot_timeout=480 \
    pcmk_reboot_retries=4"

# =============================================================================
# STEP 15 — ONE NODE ONLY: DLM + lvmlockd + LVM-activate + GFS2
# =============================================================================

echo ""
echo "========================================"
echo " [Primary only] Creating cluster resources..."
echo "========================================"

# DLM resource
run_on_primary "pcs resource create dlm ocf:pacemaker:controld op monitor interval=30s on-fail=fence clone interleave=true ordered=true"

# lvmlockd resource
run_on_primary "pcs resource create lvmlockd ocf:heartbeat:lvmlockd op monitor interval=30s on-fail=fence clone interleave=true ordered=true"

# Order: dlm → lvmlockd
run_on_primary "pcs constraint order start dlm-clone then lvmlockd-clone"
run_on_primary "pcs constraint colocation add lvmlockd-clone with dlm-clone"

echo "Waiting for DLM + lvmlockd to start on all nodes..."
sleep 15

# Create LVM objects
run_on_primary "pvcreate ${GFS2_DEVICE}"
run_on_primary "vgcreate --shared clustervg ${GFS2_DEVICE}"
run_on_primary "lvcreate -L${GFS2_SIZE} -n clusterlv clustervg"
run_on_primary "vgchange --lock-start clustervg"
run_on_primary "vgchange -asy clustervg"
run_on_primary "mkfs.gfs2 -j${GFS2_JOURNALS} -p lock_dlm -t ${GFS2_TABLE_NAME} /dev/clustervg/clusterlv"
run_on_primary "vgchange -an clustervg"

# LVM-activate resource
run_on_primary "pcs resource create clusterfs_lvm ocf:heartbeat:LVM-activate \
    vgname=clustervg \
    vg_access_mode=lvmlockd \
    activation_mode=shared \
    op monitor interval=30s on-fail=fence \
    clone interleave=true ordered=true"

# Order: lvmlockd → LVM-activate
run_on_primary "pcs constraint order start lvmlockd-clone then clusterfs_lvm-clone"
run_on_primary "pcs constraint colocation add clusterfs_lvm-clone with lvmlockd-clone"

# Filesystem resource
run_on_primary "pcs resource create clusterfs ocf:heartbeat:Filesystem \
    device='/dev/clustervg/clusterlv' \
    directory='${GFS2_MOUNT}' \
    fstype='gfs2' \
    options='noatime' \
    op monitor interval=10s on-fail=fence \
    clone interleave=true"

# Order: LVM-activate → Filesystem
run_on_primary "pcs constraint order start clusterfs_lvm-clone then clusterfs-clone"
run_on_primary "pcs constraint colocation add clusterfs-clone with clusterfs_lvm-clone"

run_on_primary "pcs resource cleanup"

# =============================================================================
# STEP 16 — Final status + summary
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
  "${SSH_USER}@${PUBLIC_IPS[0]}" \
  "sudo pcs status"

echo ""
echo "========================================"
echo " DONE — Cluster Summary"
echo "========================================"
printf "%-12s %-22s %-22s %-16s\n" "Name" "Instance ID" "Private IP" "Public IP"
printf "%-12s %-22s %-22s %-16s\n" "----" "-----------" "----------" "---------"
for i in "${!NODE_NAMES[@]}"; do
  printf "%-12s %-22s %-22s %-16s\n" "${NODE_NAMES[$i]}" "${INSTANCE_IDS[$i]}" "${PRIVATE_IPS[$i]}" "${PUBLIC_IPS[$i]}"
done
echo ""
echo "Kernel: ${KERNEL_VERSION}-custom"
echo "Fencing map:"
echo "  $FENCING_MAP"
echo ""
echo "To verify fencing manually:"
echo "  sudo fence_aws -o list --region $REGION --verbose"
echo "  sudo pcs stonith show clusterfence"
