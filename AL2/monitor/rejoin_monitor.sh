#!/bin/bash
# fence_rejoin_monitor.sh
# Run this on the SURVIVOR node before you start the rejoin procedure.
# It monitors the cluster until the rejoining node is fully Online.

LOG_DIR="/var/log/rejoin_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
echo "Logging rejoin to: $LOG_DIR"

PIDS=()

# --- Live pacemaker journal ---
sudo journalctl -u pacemaker -f --no-pager > "$LOG_DIR/pacemaker_journal.log" 2>&1 &
PIDS+=($!)
echo "[+] pacemaker journal  -> $LOG_DIR/pacemaker_journal.log (PID ${PIDS[-1]})"

# --- Live corosync journal ---
sudo journalctl -u corosync -f --no-pager > "$LOG_DIR/corosync_journal.log" 2>&1 &
PIDS+=($!)
echo "[+] corosync journal   -> $LOG_DIR/corosync_journal.log (PID ${PIDS[-1]})"

# --- crm_mon snapshots ---
(
  while true; do
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_DIR/crm_mon.log"
    sudo crm_mon -fArD -1 2>&1        >> "$LOG_DIR/crm_mon.log"
    echo ""                                       >> "$LOG_DIR/crm_mon.log"
    sleep 3
  done
) &
PIDS+=($!)
echo "[+] crm_mon snapshots  -> $LOG_DIR/crm_mon.log (PID ${PIDS[-1]})"

# --- quorum snapshots ---
(
  while true; do
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_DIR/quorum.log"
    sudo corosync-quorumtool -l 2>&1              >> "$LOG_DIR/quorum.log"
    echo ""                                       >> "$LOG_DIR/quorum.log"
    sleep 3
  done
) &
PIDS+=($!)
echo "[+] quorum snapshots   -> $LOG_DIR/quorum.log (PID ${PIDS[-1]})"

# --- pcs status snapshots ---
(
  while true; do
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_DIR/pcs_status.log"
    sudo pcs status 2>&1                          >> "$LOG_DIR/pcs_status.log"
    echo ""                                       >> "$LOG_DIR/pcs_status.log"
    sleep 3
  done
) &
PIDS+=($!)
echo "[+] pcs status snapshots -> $LOG_DIR/pcs_status.log (PID ${PIDS[-1]})"

# --- stonith history snapshots ---
(
  while true; do
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_DIR/stonith_history.log"
    sudo pcs stonith history 2>&1                 >> "$LOG_DIR/stonith_history.log"
    echo ""                                       >> "$LOG_DIR/stonith_history.log"
    sleep 3
  done
) &
PIDS+=($!)
echo "[+] stonith snapshots  -> $LOG_DIR/stonith_history.log (PID ${PIDS[-1]})"

# --- GFS2 mount health snapshots ---
(
  while true; do
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_DIR/gfs2_mount.log"
    df -h /sharedFS 2>&1                          >> "$LOG_DIR/gfs2_mount.log"
    sudo mount | grep gfs2 2>&1                   >> "$LOG_DIR/gfs2_mount.log"
    echo ""                                       >> "$LOG_DIR/gfs2_mount.log"
    sleep 3
  done
) &
PIDS+=($!)
echo "[+] GFS2 mount health  -> $LOG_DIR/gfs2_mount.log (PID ${PIDS[-1]})"

# --- Auto-stop when rejoining node comes Online ---
# Edit REJOIN_NODE to match the hostname of the node that is rejoining
REJOIN_NODE="${1:-}"
if [[ -n "$REJOIN_NODE" ]]; then
  echo ""
  echo "[*] Will auto-stop collectors when $REJOIN_NODE comes Online..."
  (
    while true; do
      sleep 5
      if sudo pcs status nodes | grep -q "Online:.*$REJOIN_NODE"; then
        echo ""
        echo "[✓] $REJOIN_NODE is Online. Stopping collectors in 15s (capturing final state)..."
        sleep 15
        kill "${PIDS[@]}" 2>/dev/null
        echo "[✓] Collectors stopped."
        exit 0
      fi
    done
  ) &
fi

# Save PIDs
echo "${PIDS[@]}" > "$LOG_DIR/collector.pids"
echo ""
echo "Collectors running. Pass node name as argument for auto-stop:"
echo "  bash fence_rejoin_monitor.sh <rejoining-nodename>"
echo "Or stop manually:"
echo "  kill \$(cat $LOG_DIR/collector.pids)"
echo ""

trap "echo 'Stopping collectors...'; kill ${PIDS[*]} 2>/dev/null; echo 'Done.'" SIGINT SIGTERM
wait