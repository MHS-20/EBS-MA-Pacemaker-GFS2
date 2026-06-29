# AGENTS.md — ebs-ma-pacemaker-gfs2

## What this repo is

Tooling and documentation for a Pacemaker + GFS2 cluster on AWS EC2. Two OS targets exist in separate directories — **they differ significantly**.

## Directory map

| Path | OS | Package source | Lock manager | Auth command |
|------|----|----------------|--------------|-------------|
| `AL2/` | Amazon Linux 2 | `yum` (packaged) | CLVM (`clvmd`) | `pcs cluster auth` |
| `AL2023/` | Amazon Linux 2023 | Source build (`gfs2-utils`, `dlm`, `lvm2`) + custom kernel | lvmlockd | `pcs host auth` |

## Quick start

**AL2 (fully automated):** edit vars at top of `AL2/launch_cluster.sh`, then run it. It launches EC2 instances from a launch template, installs everything, configures fencing, creates DLM/CLVM/GFS2 resources.

**AL2023 (fully automated):** edit vars at top of `AL2023/launch_cluster.sh`, then run it. Requires a pre-compiled kernel in S3 (build once per kernel version via `SetUpAL2023.md` section "Compile the Kernel", then share via S3). The script launches EC2 instances, downloads and installs the custom kernel, builds `gfs2-utils`/`dlm`/`lvm2` from source, installs fence-agents, and creates DLM/lvmlockd/LVM-activate/GFS2 resources.

## Critical AL2 ↔ AL2023 differences to preserve

- AL2023 requires a **custom kernel** with GFS2/DLM modules compiled in (not in stock AL2023 kernel). Build via `SetUpAL2023.md` section "Compile the Kernel". Share via S3.
- AL2023 builds `gfs2-utils`, `dlm`, `lvm2` from source (pagure.io / gitlab.com/lvmteam) — not from repos.
- AL2023 uses `lvmlockd`; AL2 uses `clvmd`. Resource order changes: `dlm → lvmlockd → LVM-activate → Filesystem` vs AL2 `dlm → clvmd → Filesystem`.
- AL2023 uses `pcs host auth` (not `pcs cluster auth`), `pcs cluster setup <name> <nodes...>` (not `--name`), and `pcs cluster enable --all`.

## Fencing

Both use `fence_aws` with IAM role. AL2 may need the shebang fix (`sed -i 's|#!/usr/bin/python|#!/usr/bin/python3.8|'`) and boto3 region patch. The IAM policy needed:

```
ec2:DescribeInstances, DescribeInstancesStatus, StartInstances, StopInstances, RebootInstances
```

## Monitor / test scripts (AL2 only)

All in `AL2/monitor/`. Run on a cluster node.

| Script | When to run | What it does |
|--------|-------------|-------------|
| `fence_monitor.sh` | Before triggering a fence | Live journal + 3s snapshots of crm_mon, quorum, stonith |
| `fence_postmortem.sh` | After fence test | Static dump of cluster state, constraints, fence events |
| `rejoin_monitor.sh [node]` | Before rejoin triggers | Like fence_monitor + GFS2 mount; auto-stops when node rejoins |
| `rejoin_postmortem.sh` | After rejoin complete | Static dump of healthy cluster |
| `download_logs.sh` | From laptop | SCP example to fetch logs from a node |

Logs land in `/var/log/` subdirectories. Use `download_logs.sh` as a template.

## Stored test logs

`AL2/logs/` contains raw output from past fence/rejoin test runs. Not needed for normal development.

## What does NOT exist

- No package.json, Makefile, or build system
- No CI/CD config
- No tests or test framework
- No existing AGENTS.md / CLAUDE.md / cursor rules
- No Terraform / CloudFormation — instances are launched from a pre-existing EC2 Launch Template
