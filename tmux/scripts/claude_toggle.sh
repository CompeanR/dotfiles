#!/bin/bash

# Claude popup toggle using session name detection (window-specific)
WINDOW_ID=$(tmux display-message -p '#{window_id}')
POPUP_SESSION="claude_popup_${WINDOW_ID}"
CURRENT_DIR="${1:-$PWD}"

# Get current session name
CURRENT_SESSION=$(tmux display-message -p '#S' 2>/dev/null)

# Check if we're already in a popup session (any claude_popup_* session)
if echo "$CURRENT_SESSION" | grep -q "^claude_popup_"; then
    # We're in a popup, detach to close it
    tmux detach-client
    exit 0
fi

# Create background session if it doesn't exist
if ! tmux has-session -t "$POPUP_SESSION" 2>/dev/null; then
    # Detect OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Create detached session with Claude
        tmux new-session -d -s "$POPUP_SESSION" -c "$CURRENT_DIR" "cd '$CURRENT_DIR' && cyc || /opt/homebrew/bin/claude"
    else
        # Create detached session with Claude in YOLO mode
        tmux new-session -d -s "$POPUP_SESSION" -c "$CURRENT_DIR" "cd '$CURRENT_DIR' && /home/compean/.nvm/versions/node/v22.17.1/bin/claude --dangerously-skip-permissions"
    fi

    # Configure session for popup use
    tmux set-option -s -t "$POPUP_SESSION" status off
fi

# Open popup that attaches to the background session
# Dynamic sizing: use 70% for large terminals, 95% for small ones
TERM_WIDTH=$(tmux display-message -p '#{client_width}')
if [ "$TERM_WIDTH" -gt 200 ]; then
    WIDTH="70%"
    HEIGHT="90%"
else
    WIDTH="95%"
    HEIGHT="95%"
fi
tmux display-popup -xC -yC -w "$WIDTH" -h "$HEIGHT" -d "$CURRENT_DIR" -E "TERM=xterm-256color tmux attach -t '$POPUP_SESSION'"
