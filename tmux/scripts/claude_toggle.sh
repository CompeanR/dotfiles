#!/bin/bash

# Claude popup toggle using session name detection (recommended approach)
POPUP_SESSION="claude_popup"
CURRENT_DIR="${1:-$PWD}"

# Get current session name
CURRENT_SESSION=$(tmux display-message -p '#S' 2>/dev/null)

# Check if we're already in the popup session
if [ "$CURRENT_SESSION" = "$POPUP_SESSION" ]; then
    # We're in the popup, detach to close it
    tmux detach-client
    exit 0
fi

# Create background session if it doesn't exist
if ! tmux has-session -t "$POPUP_SESSION" 2>/dev/null; then
    # Create detached session with Claude
    tmux new-session -d -s "$POPUP_SESSION" -c "$CURRENT_DIR" "cd '$CURRENT_DIR' && /opt/homebrew/bin/claude --resume || /opt/homebrew/bin/claude"

    # Configure session for popup use
    tmux set-option -s -t "$POPUP_SESSION" status off
fi

# Open popup that attaches to the background session
tmux display-popup -xC -yC -w 70% -h 90% -d "$CURRENT_DIR" -E "TERM=xterm-256color tmux attach -t '$POPUP_SESSION'"

