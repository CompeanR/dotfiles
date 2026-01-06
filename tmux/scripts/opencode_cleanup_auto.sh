#!/bin/bash

# Automatic Claude popup session cleanup (no confirmation)
# Silently removes orphaned Claude popup sessions at tmux startup

# Find all opencode_popup and lazydocker_popup sessions
CLAUDE_SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^opencode_popup_')
DOCKER_SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^lazydocker_popup_')

if [ -z "$CLAUDE_SESSIONS" ] && [ -z "$DOCKER_SESSIONS" ]; then
    # No sessions found, exit silently
    exit 0
fi

# Kill each claude session silently
if [ -n "$CLAUDE_SESSIONS" ]; then
    while IFS= read -r session; do
        tmux kill-session -t "$session" 2>/dev/null
    done <<<"$CLAUDE_SESSIONS"
fi

# Kill each lazydocker session silently
if [ -n "$DOCKER_SESSIONS" ]; then
    while IFS= read -r session; do
        tmux kill-session -t "$session" 2>/dev/null
    done <<<"$DOCKER_SESSIONS"
fi