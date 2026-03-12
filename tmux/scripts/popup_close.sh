#!/bin/bash
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_SCRIPT="$SCRIPT_DIR/popup_state.sh"
POPUP_SOCKET="popup-hub"

PARENT_SOCKET=$(tmux -L "$POPUP_SOCKET" display-message -p '#{@parent_socket}' 2>/dev/null || true)
PARENT_CLIENT=$(tmux -L "$POPUP_SOCKET" display-message -p '#{@parent_client}' 2>/dev/null || true)
PARENT_SESSION_ID=$(tmux -L "$POPUP_SOCKET" display-message -p '#{@parent_session_id}' 2>/dev/null || true)
PARENT_WINDOW_ID=$(tmux -L "$POPUP_SOCKET" display-message -p '#{@parent_window_id}' 2>/dev/null || true)

if [ -z "$PARENT_SOCKET" ] || [ -z "$PARENT_CLIENT" ] || [ -z "$PARENT_SESSION_ID" ] || [ -z "$PARENT_WINDOW_ID" ]; then
    exit 0
fi

tmux_parent() {
    tmux -S "$PARENT_SOCKET" "$@"
}

resolve_parent_client() {
    if tmux_parent display-message -c "$PARENT_CLIENT" -p '#{client_tty}' >/dev/null 2>&1; then
        printf '%s' "$PARENT_CLIENT"
        return 0
    fi

    local session_client=""
    local fallback_client=""
    session_client=$(tmux_parent list-clients -F '#{client_tty} #{session_id}' 2>/dev/null | awk -v sid="$PARENT_SESSION_ID" '$2 == sid { print $1; exit }' || true)
    if [ -n "$session_client" ]; then
        printf '%s' "$session_client"
        return 0
    fi

    fallback_client=$(tmux_parent list-clients -F '#{client_tty}' 2>/dev/null | head -n1 || true)
    printf '%s' "$fallback_client"
}

TARGET_PARENT_CLIENT=$(resolve_parent_client || true)
CURRENT_PARENT_SESSION_ID=$(tmux_parent display-message -c "$TARGET_PARENT_CLIENT" -p '#{session_id}' 2>/dev/null || printf '%s' "$PARENT_SESSION_ID")
CURRENT_PARENT_WINDOW_ID=$(tmux_parent display-message -c "$TARGET_PARENT_CLIENT" -p '#{window_id}' 2>/dev/null || printf '%s' "$PARENT_WINDOW_ID")

"$STATE_SCRIPT" clear-tool "$PARENT_SOCKET" "$TARGET_PARENT_CLIENT" "$CURRENT_PARENT_SESSION_ID" "$CURRENT_PARENT_WINDOW_ID" || true
"$STATE_SCRIPT" clear-nav "$PARENT_SOCKET" "$TARGET_PARENT_CLIENT" "$CURRENT_PARENT_SESSION_ID" "$CURRENT_PARENT_WINDOW_ID" || true

detach_popup_client() {
    local popup_client=""
    popup_client=$(tmux -L "$POPUP_SOCKET" display-message -p '#{client_tty}' 2>/dev/null || true)
    
    if [ -n "$popup_client" ]; then
        tmux -L "$POPUP_SOCKET" detach-client -t "$popup_client" 2>/dev/null || true
        return 0
    fi

    local fallback_client=""
    fallback_client=$(tmux -L "$POPUP_SOCKET" list-clients -F '#{client_tty}' 2>/dev/null | head -n1 || true)
    if [ -n "$fallback_client" ]; then
        tmux -L "$POPUP_SOCKET" detach-client -t "$fallback_client" 2>/dev/null || true
    fi
}

detach_popup_client

exit 0
