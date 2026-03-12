#!/bin/bash

# Automatic popup session cleanup (no confirmation)
# Silently removes orphaned popup sessions at tmux startup
# Handles popup sessions on the popup-hub socket

CODEX_SESSIONS=$(tmux -L popup-hub list-sessions -F '#{session_name}' 2>/dev/null | grep '^codex_popup_')
CLAUDE_SESSIONS=$(tmux -L popup-hub list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude_popup_')
TERMINAL_SESSIONS=$(tmux -L popup-hub list-sessions -F '#{session_name}' 2>/dev/null | grep '^terminal_popup_')
OPENCODE_SESSIONS=$(tmux -L popup-hub list-sessions -F '#{session_name}' 2>/dev/null | grep '^opencode_popup_')
LAZYDOCKER_SESSIONS=$(tmux -L popup-hub list-sessions -F '#{session_name}' 2>/dev/null | grep '^lazydocker_popup_')

if [ -z "$CODEX_SESSIONS" ] && [ -z "$CLAUDE_SESSIONS" ] && [ -z "$TERMINAL_SESSIONS" ] && [ -z "$OPENCODE_SESSIONS" ] && [ -z "$LAZYDOCKER_SESSIONS" ]; then
    exit 0
fi

cleanup_sessions() {
    local sessions="$1"

    if [ -z "$sessions" ]; then
        return
    fi

    while IFS= read -r session; do
        tmux -L popup-hub kill-session -t "$session" 2>/dev/null
    done <<< "$sessions"
}

cleanup_sessions "$CODEX_SESSIONS"
cleanup_sessions "$CLAUDE_SESSIONS"
cleanup_sessions "$TERMINAL_SESSIONS"
cleanup_sessions "$OPENCODE_SESSIONS"
cleanup_sessions "$LAZYDOCKER_SESSIONS"
