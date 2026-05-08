#!/bin/bash
# fence_rejoin_postmortem.sh
# Captures the final healthy state after the node has fully rejoined.

LOG_DIR="/var/log/fence_rejoin_postmortem_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
echo "Saving rejoin post-mortem to: $LOG_DIR"

echo "[+] pcs status --full"
sudo pcs status --full > "$LOG_DIR/pcs_status_full.log" 2>&1

echo "[+] pcs status nodes"
sudo pcs status nodes > "$LOG_DIR/pcs_nodes.log" 2>&1

echo "[+] crm_mon full snapshot"
sudo crm_mon -fAr -1 > "$LOG_DIR/crm_mon.log" 2>&1

echo "[+] corosync quorum"
sudo corosync-quorumtool -l > "$LOG_DIR/quorum.log" 2>&1

echo "[+] stonith history"
sudo pcs stonith history > "$LOG_DIR/stonith_history.log" 2>&1

echo "[+] pcs constraints"
sudo pcs constraint > "$LOG_DIR/constraints.log" 2>&1

echo "[+] GFS2 mount state"
df -h /sharedFS > "$LOG_DIR/gfs2_mount.log" 2>&1
sudo mount | grep gfs2 >> "$LOG_DIR/gfs2_mount.log" 2>&1

echo "[+] pacemaker journal (last 300 lines)"
sudo journalctl -u pacemaker --no-pager -n 300 > "$LOG_DIR/pacemaker_journal.log" 2>&1

echo "[+] corosync journal (last 300 lines)"
sudo journalctl -u corosync --no-pager -n 300 > "$LOG_DIR/corosync_journal.log" 2>&1

echo "[+] rejoin-related log lines"
sudo journalctl -u pacemaker -u corosync --no-pager \
  | grep -iE "online|joined|member|quorum|start|fence|unclean" \
  > "$LOG_DIR/rejoin_events.log" 2>&1

echo "[+] failed actions check"
sudo pcs status | grep -iE "failed|error|unclean|offline" \
  > "$LOG_DIR/failed_actions.log" 2>&1 \
  || echo "No failed actions found" > "$LOG_DIR/failed_actions.log"

echo ""
echo "Done. Files in: $LOG_DIR"
ls -lh "$LOG_DIR"