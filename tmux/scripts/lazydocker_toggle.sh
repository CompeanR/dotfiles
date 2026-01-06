#!/bin/bash

# Lazydocker popup toggle using session name detection (window-specific)
WINDOW_ID=$(tmux display-message -p '#{window_id}')
POPUP_SESSION="lazydocker_popup_${WINDOW_ID}"
CURRENT_DIR="${1:-$PWD}"

# Get current session name
CURRENT_SESSION=$(tmux display-message -p '#S' 2>/dev/null)

# Check if we're already in a popup session (any lazydocker_popup_* session)
if echo "$CURRENT_SESSION" | grep -q "^lazydocker_popup_"; then
    # We're in a popup, detach to close it
    tmux detach-client
    exit 0
fi

# Create background session if it doesn't exist
if ! tmux has-session -t "$POPUP_SESSION" 2>/dev/null; then
    # Create detached session with lazydocker
    tmux new-session -d -s "$POPUP_SESSION" -c "$CURRENT_DIR" "cd '$CURRENT_DIR' && lazydocker"

    # Configure session for popup use
    tmux set-option -s -t "$POPUP_SESSION" status off
fi

# Open popup that attaches to the background session
tmux display-popup -xC -yC -w 90% -h 90% -d "$CURRENT_DIR" -E "TERM=xterm-256color tmux attach -t '$POPUP_SESSION'"
