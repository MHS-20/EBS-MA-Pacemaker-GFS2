#!/bin/bash
# fence_monitor_live.sh
# Run this BEFORE triggering the fence. It collects live logs in the background.
# Stop it after the fenced node has rejoined (or after you're done testing).

LOG_DIR="/var/log/fence_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
echo "Logging to: $LOG_DIR"

# --- Live journal for pacemaker ---
sudo journalctl -u pacemaker -f --no-pager > "$LOG_DIR/pacemaker_journal.log" 2>&1 &
PIDS+=($!)
echo "[+] pacemaker journal -> $LOG_DIR/pacemaker_journal.log (PID ${PIDS[-1]})"

# --- Live journal for corosync ---
sudo journalctl -u corosync -f --no-pager > "$LOG_DIR/corosync_journal.log" 2>&1 &
PIDS+=($!)
echo "[+] corosync journal  -> $LOG_DIR/corosync_journal.log (PID ${PIDS[-1]})"

# --- crm_mon snapshots every 3 seconds ---
(
  while true; do
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_DIR/crm_mon.log"
    sudo crm_mon -fArD -1 2>&1   >> "$LOG_DIR/crm_mon.log"
    echo "" >> "$LOG_DIR/crm_mon.log"
    sleep 3
  done
) &
PIDS+=($!)
echo "[+] crm_mon snapshots -> $LOG_DIR/crm_mon.log (PID ${PIDS[-1]})"

# --- corosync quorum snapshots every 3 seconds ---
(
  while true; do
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_DIR/quorum.log"
    sudo corosync-quorumtool -l 2>&1          >> "$LOG_DIR/quorum.log"
    echo "" >> "$LOG_DIR/quorum.log"
    sleep 3
  done
) &
PIDS+=($!)
echo "[+] quorum snapshots  -> $LOG_DIR/quorum.log (PID ${PIDS[-1]})"

# --- stonith history snapshots every 3 seconds ---
(
  while true; do
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_DIR/stonith_history.log"
    sudo pcs stonith history 2>&1              >> "$LOG_DIR/stonith_history.log"
    echo "" >> "$LOG_DIR/stonith_history.log"
    sleep 3
  done
) &
PIDS+=($!)
echo "[+] stonith snapshots -> $LOG_DIR/stonith_history.log (PID ${PIDS[-1]})"

# --- Save PID list so you can kill cleanly ---
echo "${PIDS[@]}" > "$LOG_DIR/collector.pids"
echo ""
echo "All collectors running. To stop:"
echo "  kill \$(cat $LOG_DIR/collector.pids)"
echo "  or just run: sudo kill ${PIDS[*]}"

# Wait and trap Ctrl+C for clean shutdown
trap "echo 'Stopping collectors...'; kill ${PIDS[*]} 2>/dev/null; echo 'Done.'" SIGINT SIGTERM
wait