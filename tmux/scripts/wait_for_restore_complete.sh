#!/bin/bash

LOG_FILE="/tmp/tmux_restore_debug.log"
echo "---" >> $LOG_FILE
echo "$(date): wait_for_restore_complete.sh started" >> $LOG_FILE

# Wait for tmux-resurrect to complete by checking for active restoration
MAX_WAIT=30  # Maximum 30 seconds
COUNTER=0

# Check if tmux-resurrect restore process is running
while [ $COUNTER -lt $MAX_WAIT ]; do
    # Check if any pane is still running the restore script
    if ! tmux list-panes -a -F '#{pane_current_command}' 2>/dev/null | grep -q "restore.sh"; then
        echo "$(date): No restore.sh process found. Waiting 3 seconds before cleanup." >> $LOG_FILE
        # Wait additional 3 seconds for processes to spawn
        sleep 3
        echo "$(date): Running cleanup script." >> $LOG_FILE
        # Run cleanup
        "$(dirname "$0")/claude_cleanup_auto.sh"
        echo "$(date): Cleanup script finished." >> $LOG_FILE
        tmux list-sessions >> $LOG_FILE # Log existing sessions after cleanup
        exit 0
    fi
    echo "$(date): restore.sh process found. Waiting..." >> $LOG_FILE
    sleep 1
    ((COUNTER++))
done

echo "$(date): Timeout waiting for restore to complete" >> $LOG_FILE