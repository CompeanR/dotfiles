#!/bin/bash

# Opencode popup toggle using session name detection (window-specific)
WINDOW_ID=$(tmux display-message -p '#{window_id}')
POPUP_SESSION="opencode_popup_${WINDOW_ID}"
CURRENT_DIR="${1:-$PWD}"

# Get current session name
CURRENT_SESSION=$(tmux display-message -p '#S' 2>/dev/null)

# Check if we're already in a popup session (any opencode_popup_* session)
if echo "$CURRENT_SESSION" | grep -q "^opencode_popup_"; then
    # We're in a popup, detach to close it
    tmux detach-client
    exit 0
fi

# Create background session if it doesn't exist
if ! tmux has-session -t "$POPUP_SESSION" 2>/dev/null; then
    # Detect OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Create detached session with Opencode
        tmux new-session -d -s "$POPUP_SESSION" -c "$CURRENT_DIR" "cd '$CURRENT_DIR' && opencode -c || opencode"
    else
        # Create detached session with Opencode (source environment for MCP servers)
        tmux new-session -d -s "$POPUP_SESSION" -c "$CURRENT_DIR" "source ~/.zshrc && cd '$CURRENT_DIR' && opencode -c || opencode"
    fi

    # Configure session for popup use
    tmux set-option -s -t "$POPUP_SESSION" status off
fi

# Open popup that attaches to the background session
tmux display-popup -xC -yC -w 75% -h 90% -d "$CURRENT_DIR" -E "TERM=xterm-256color tmux attach -t '$POPUP_SESSION'"
