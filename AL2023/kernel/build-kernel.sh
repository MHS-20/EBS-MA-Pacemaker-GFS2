#!/bin/bash
# =============================================================================
# AL2023 Kernel Builder
# Launches an m7i.4xlarge instance, compiles a custom kernel with GFS2+DLM
# modules, packages it, uploads to S3, and terminates the instance.
#
# Prerequisites:
#   - AWS CLI v2 configured with sufficient permissions
#   - IAM instance profile with EC2 run-instances + S3 PutObject access
#   - SSH key pair accessible locally
#
# Output: S3://<BUCKET>/kernel-<VERSION>-custom.tar.gz
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — edit these before running
# =============================================================================

AMI_ID="ami-05cbf8a8aa4e4b755"       # AL2023
INSTANCE_TYPE="m7i.4xlarge"
REGION="eu-west-1"
KEY_NAME="muhamad-keypair"
SSH_KEY_PATH="~/.ssh/id_ed25519"
SSH_USER="ec2-user"
IAM_PROFILE="ec2-fencing-test"
S3_BUCKET="s3://muhamad-tirocinio-bucket-861507897222-eu-west-1-an"

# =============================================================================
# STEP 1 — Launch the build instance
# =============================================================================

echo "========================================"
echo " Launching kernel build instance..."
echo "========================================"

INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --iam-instance-profile "Name=${IAM_PROFILE}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=kernel-builder}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance ID: $INSTANCE_ID"

echo "Waiting for instance to reach 'running' state..."
aws ec2 wait instance-running \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID"

PRIVATE_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

echo "Private IP: $PRIVATE_IP"

# =============================================================================
# STEP 2 — Wait for SSH
# =============================================================================

echo ""
echo "Waiting for SSH..."
until ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=5 \
  -o BatchMode=yes \
  "${SSH_USER}@${PRIVATE_IP}" "echo ok" &>/dev/null; do
  echo -n "."
  sleep 5
done
echo " ready"

run() {
  local CMD="$1"
  echo "[instance] Running: ${CMD:0:80}..."
  ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    "${SSH_USER}@${PRIVATE_IP}" "sudo bash -c '$CMD'" 2>&1
}

run_user() {
  local CMD="$1"
  echo "[instance] Running: ${CMD:0:80}..."
  ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    "${SSH_USER}@${PRIVATE_IP}" "bash -c '$CMD'" 2>&1
}

# =============================================================================
# STEP 3 — Install build dependencies
# =============================================================================

echo ""
echo "========================================"
echo " Installing build dependencies..."
echo "========================================"

run "dnf groupinstall 'Development Tools' -y"
run "dnf install -y openssl-devel elfutils-libelf-devel bc flex bison perl ncurses-devel dwarves rsync wget curl git hmaccalc python3-devel perl-generators perl-ExtUtils-Embed dnf-utils"

# =============================================================================
# STEP 4 — Download and extract kernel source
# =============================================================================

echo ""
echo "========================================"
echo " Downloading kernel source..."
echo "========================================"

KERNEL_VERSION=$(ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o BatchMode=yes \
  "${SSH_USER}@${PRIVATE_IP}" "uname -r")
echo "Stock kernel version: $KERNEL_VERSION"

run_user "cd /tmp && dnf download --source kernel-${KERNEL_VERSION}"
run_user "cd /tmp && rpm -ivh kernel-*.src.rpm"
run "dnf builddep -y ~/rpmbuild/SPECS/kernel.spec"
run_user "cd ~/rpmbuild/SPECS && rpmbuild -bp --target=\$(uname -m) kernel.spec"

# =============================================================================
# STEP 5 — Configure kernel
# =============================================================================

echo ""
echo "========================================"
echo " Configuring kernel..."
echo "========================================"

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && cp /boot/config-\$(uname -r) .config && make olddefconfig"

# Enable GFS2 and DLM modules
run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && \
  ./scripts/config --module CONFIG_GFS2_FS && \
  ./scripts/config --enable CONFIG_DLM && \
  ./scripts/config --module CONFIG_DLM_LOCK_DLM && \
  ./scripts/config --enable CONFIG_GFS2_FS_LOCKING_DLM && \
  ./scripts/config --enable CONFIG_CONFIGFS_FS && \
  ./scripts/config --enable CONFIG_SYSFS && \
  ./scripts/config --enable CONFIG_DLM_DEBUG"

# Nitro-specific drivers (m7i is Nitro-based)
run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && \
  ./scripts/config --enable CONFIG_AMAZON_ENA_ETHERNET && \
  ./scripts/config --enable CONFIG_NVME_CORE && \
  ./scripts/config --enable CONFIG_BLK_DEV_NVME"

# Disable module signing to avoid signing key errors
run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && \
  ./scripts/config --disable CONFIG_MODULE_SIG_FORCE"

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make olddefconfig"

# Verify config
run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && grep -E 'CONFIG_GFS2|CONFIG_DLM' .config"

# =============================================================================
# STEP 6 — Compile the kernel
# =============================================================================

echo ""
echo "========================================"
echo " Compiling kernel (this takes a while)..."
echo "========================================"

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make -j\$(nproc) 2>&1 | tee /tmp/build.log"
run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make -j\$(nproc) M=fs/gfs2 M=fs/dlm 2>&1"

# =============================================================================
# STEP 7 — Install modules and prepare kernel artifacts
# =============================================================================

echo ""
echo "========================================"
echo " Installing modules and packaging..."
echo "========================================"

run "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make modules_install"
run "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make install"

KERNEL_RELEASE=$(ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o BatchMode=yes \
  "${SSH_USER}@${PRIVATE_IP}" \
  "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make kernelrelease")

echo "Kernel release: $KERNEL_RELEASE"

run "dracut --force /boot/initramfs-${KERNEL_RELEASE}.img ${KERNEL_RELEASE}"
run "mv /boot/vmlinuz /boot/vmlinuz-${KERNEL_RELEASE}-custom"
run "mv /boot/initramfs-${KERNEL_RELEASE}.img /boot/initramfs-${KERNEL_RELEASE}-custom.img"

# Add GRUB entry (for local testing, not strictly needed for packaging)
run "grubby --add-kernel=/boot/vmlinuz-${KERNEL_RELEASE}-custom --initrd=/boot/initramfs-${KERNEL_RELEASE}-custom.img --title='Linux ${KERNEL_RELEASE} custom (GFS2+DLM)' --copy-default --make-default || true"

# =============================================================================
# STEP 8 — Package and upload to S3
# =============================================================================

echo ""
echo "========================================"
echo " Packaging kernel artifacts..."
echo "========================================"

ARCHIVE="kernel-${KERNEL_RELEASE}-custom.tar.gz"

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && sudo tar -czf /tmp/${ARCHIVE} /boot/vmlinuz-${KERNEL_RELEASE}-custom /boot/initramfs-${KERNEL_RELEASE}-custom.img /lib/modules/${KERNEL_RELEASE}/"
run "chown ${SSH_USER}:${SSH_USER} /tmp/${ARCHIVE}"

echo ""
echo "========================================"
echo " Uploading to S3..."
echo "========================================"

ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o BatchMode=yes \
  "${SSH_USER}@${PRIVATE_IP}" \
  "aws s3 cp /tmp/${ARCHIVE} ${S3_BUCKET}/"

echo ""
echo "Upload complete: ${S3_BUCKET}/${ARCHIVE}"

# =============================================================================
# STEP 9 — Cleanup: terminate the build instance
# =============================================================================

echo ""
echo "========================================"
echo " Terminating build instance..."
echo "========================================"

aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "Instance $INSTANCE_ID terminated."

echo ""
echo "========================================"
echo " DONE"
echo "========================================"
echo "Kernel: $KERNEL_RELEASE"
echo "Archive: ${S3_BUCKET}/${ARCHIVE}"
echo ""
echo "To use this kernel in AL2023/launch_cluster.sh, update:"
echo "  KERNEL_VERSION=\"$KERNEL_RELEASE\""
echo "  KERNEL_FILE=\"kernel-${KERNEL_RELEASE}-custom.tar.gz\""
