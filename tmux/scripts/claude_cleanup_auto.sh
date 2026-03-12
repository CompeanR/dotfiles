#!/bin/bash

# Automatic Claude popup session cleanup (no confirmation)
# Silently removes orphaned Claude popup sessions at tmux startup

# Find all claude_popup sessions on popup-hub socket
CLAUDE_SESSIONS=$(tmux -L popup-hub list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude_popup_')

if [ -z "$CLAUDE_SESSIONS" ]; then
    # No sessions found, exit silently
    exit 0
fi

# Count sessions for logging
SESSION_COUNT=$(echo "$CLAUDE_SESSIONS" | wc -l | tr -d ' ')

# Kill each session silently
KILLED_COUNT=0
while IFS= read -r session; do
    if tmux -L popup-hub kill-session -t "$session" 2>/dev/null; then
        ((KILLED_COUNT++))
    fi
done <<< "$CLAUDE_SESSIONS"

# Optional: Log cleanup (comment out if you don't want any output)
# echo "🧹 Cleaned up $KILLED_COUNT Claude popup sessions"