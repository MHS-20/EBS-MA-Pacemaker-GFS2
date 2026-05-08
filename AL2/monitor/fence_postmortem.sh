#!/bin/bash
# fence_postmortem.sh
# Run this after the fence test is complete to capture the final state.

LOG_DIR="/var/log/fence_postmortem_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
echo "Saving post-mortem logs to: $LOG_DIR"

# --- Cluster status ---
echo "[+] pcs status"
sudo pcs status --full > "$LOG_DIR/pcs_status.log" 2>&1

# --- Node list ---
echo "[+] pcs status nodes"
sudo pcs status nodes > "$LOG_DIR/pcs_nodes.log" 2>&1

# --- Stonith history ---
echo "[+] stonith history"
sudo pcs stonith history > "$LOG_DIR/stonith_history.log" 2>&1

# --- Quorum state ---
echo "[+] corosync-quorumtool"
sudo corosync-quorumtool -l > "$LOG_DIR/quorum.log" 2>&1

# --- crm_mon full snapshot ---
echo "[+] crm_mon"
sudo crm_mon -fAr -1 > "$LOG_DIR/crm_mon.log" 2>&1

# --- Last 500 lines of pacemaker journal ---
echo "[+] pacemaker journal (last 500 lines)"
sudo journalctl -u pacemaker --no-pager -n 500 > "$LOG_DIR/pacemaker_journal.log" 2>&1

# --- Last 500 lines of corosync journal ---
echo "[+] corosync journal (last 500 lines)"
sudo journalctl -u corosync --no-pager -n 500 > "$LOG_DIR/corosync_journal.log" 2>&1

# --- Fence-related lines extracted from journals ---
echo "[+] fence-related log lines"
sudo journalctl -u pacemaker -u corosync --no-pager \
  | grep -iE "fence|stonith|reboot|lost|unclean|offline" \
  > "$LOG_DIR/fence_events.log" 2>&1

# --- Resource constraints ---
echo "[+] pcs constraint"
sudo pcs constraint > "$LOG_DIR/constraints.log" 2>&1

echo ""
echo "Done. Files saved in: $LOG_DIR"
ls -lh "$LOG_DIR"