# SetUp AL2: GFS2 + Pacemaker

## Pacemaker Cluster Set Up

Use Amazon Linux 2.

On all nodes: 

```bash
sudo yum update -y
sudo yum install pcs pacemaker -y
sudo systemctl enable --now pcsd.service
sudo systemctl enable corosync pacemaker

# use same password on all nodes 
echo "hacluster:pass" | sudo chpasswd
```

On all nodes edit `/etc/hosts` to resolve the names of all other nodes to the private IPs in the VPC: 

```bash
sudo tee -a /etc/hosts <<EOF
172.31.33.18   ma-host-1
172.31.41.23   ma-host-2
172.31.47.118   ma-host-3
172.31.37.191    ma-host-4
172.31.46.92   ma-host-5
EOF
```

Check connectivity: 

```bash
ping ma-host-1
ping ma-host-2
ping ma-host-3
ping ma-host-4
ping ma-host-5
```

On one node only: 

```bash
# sudo pcs cluster auth
sudo pcs cluster auth ma-host-1 ma-host-2 ma-host-3 ma-host-4 ma-host-5 -u hacluster -p pass
sudo pcs cluster setup --name macluster ma-host-1 ma-host-2 ma-host-3 ma-host-4 ma-host-5
sudo pcs cluster start --all
watch sudo pcs status
```

## Fencing Set Up

On all nodes, install updated versions of python and aws-cli:

```bash
sudo yum remove -y python2 python2-pip python2-boto3

sudo amazon-linux-extras install python3.8 -y
sudo yum install -y python38-devel libcurl-devel gcc openssl-devel 
sudo yum install -y fence-agents-aws

sudo /usr/bin/python3.8 -m ensurepip --upgrade
sudo /usr/bin/python3.8 -m pip install \
  "urllib3<2.0" \
  boto3 botocore requests pexpect pycurl certifi \
  --upgrade
```

```bash
sudo yum remove -y awscli 
rm -rf aws/

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/

echo 'export PATH=/usr/local/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
aws --version
```

For the fence agent, choose one of this two option:

1. Fix the fence agent code, on all nodes (if you want to keep using an old version, like 4.2):
    
    ```bash
    sudo sed -i 's|#!/usr/bin/python|#!/usr/bin/python3.8|' /usr/sbin/fence_aws
    sudo sed -i "s/conn = boto3.resource('ec2')/conn = boto3.resource('ec2', region_name=options.get('--region'))/" /usr/sbin/fence_aws
    ```
    
2. Otherwise download and build latest fence agent code (on all nodes):
    
    ```bash
    sudo yum install -y git autoconf automake libtool make gcc
    
    cd /tmp
    git clone https://github.com/ClusterLabs/fence-agents.git
    cd fence-agents
    ./autogen.sh
    ./configure --with-agents=aws \
      PYTHON=/usr/bin/python3.8 \
      PYTHON_VERSION=3.8
    make
    sudo make install
    fence_aws --version
    ```
    

Enable fencing (on all nodes):

```bash
sudo pcs property set stonith-enabled=true
sudo pcs property set stonith-action=off
sudo pcs property set startup-fencing=true
sudo pcs property set no-quorum-policy=stop
sudo pcs property set stonith-timeout=600s
```

In case of errors: 

```bash
sudo journalctl -u pacemaker --no-pager | grep -i fence | tail -30
sudo tail -50 /var/log/cluster/corosync.log
```

Assign a IAM role with the correct permissions to all EC2 istances: 

```yaml
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstancesStatus",
        "ec2:StartInstances",
        "ec2:StopInstances",
        "ec2:RebootInstances"
      ],
      "Resource": "*"
    }
  ]
}
```

Then set up fencing using the IAM role (only on one node):

```bash
sudo pcs stonith create clusterfence fence_aws \
  region=eu-west-1 \
  pcmk_host_map="ma-host-1:i-0dd4e70251540b226;ma-host-2:i-020f74f3159554633;ma-host-3:i-01c5761b18d91afab;ma-host-4:i-0619c5f5e07752b6e;ma-host-5:i-003dbfa3f192dedd9" \
  power_timeout=600 pcmk_off_timeout=600 pcmk_reboot_timeout=480 pcmk_reboot_retries=4 power_wait=5
```

In case of error, launch the agent manually in verbose mode:

```bash
fence_aws -o status -n i-0d6dcd2303280703f --region eu-west-1 --plug i-0d6dcd2303280703f --verbose
AWS_DEFAULT_REGION=eu-west-1 fence_aws -o status -n i-0d6dcd2303280703f --region eu-west-1 --plug i-0d6dcd2303280703f --verbose
sudo env -i HOME=/root PATH=/usr/sbin:/usr/bin fence_aws -o monitor --region eu-west-1 2>&1
```

To reload the fence agent after some changes:

```bash
sudo pcs resource cleanup clusterfence
sudo pcs resource enable clusterfence
sudo pcs status
```

## GFS2 Set Up

On all nodes:

```bash
sudo yum install lvm2-cluster gfs2-utils dlm -y
sudo /sbin/lvmconf --enable-cluster
sudo mkdir /sharedFS
```

Only on one node:

```bash
sudo pcs resource create dlm ocf:pacemaker:controld op monitor interval=30s \
 on-fail=fence clone interleave=true ordered=true

sudo pcs resource create clvmd ocf:heartbeat:clvm op monitor interval=30s \
on-fail=fence clone interleave=true ordered=true

sudo pcs constraint order start dlm-clone then clvmd-clone
sudo pcs constraint colocation add clvmd-clone with dlm-clone

sudo pvcreate /dev/nvme1n1  
sudo vgcreate -Ay -cy clustervg /dev/nvme1n1  
sudo lvcreate -L20G -n clusterlv clustervg
sudo vgchange -ay clustervg

sudo mkfs.gfs2 -j5 -p lock_dlm -t macluster:sharedFS /dev/clustervg/clusterlv

sudo pcs resource create clusterfs Filesystem device="/dev/clustervg/clusterlv" \
directory="/sharedFS" fstype="gfs2" options="noatime" op monitor interval=10s \
on-fail=fence clone interleave=true

sudo pcs constraint order start clvmd-clone then clusterfs-clone
sudo pcs constraint colocation add clusterfs-clone with clvmd-clone
sudo pcs resource cleanup clusterfs
```

In case of errors, try cleaning up the resources:

```bash
sudo pcs resource cleanup clusterfs
```

Or try to force LVM to rescan and activate the VG (on the broken nodes):

```bash
sudo pvscan --cache
sudo vgscan
sudo vgchange -ay clustervg
sudo lvs
```