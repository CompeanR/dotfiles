#!/bin/bash
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_SCRIPT="$SCRIPT_DIR/popup_state.sh"
POPUP_SOCKET="popup-hub"

ACTION="${1:-}"

PARENT_SOCKET=$(tmux -L "$POPUP_SOCKET" display-message -p '#{@parent_socket}' 2>/dev/null || true)
PARENT_CLIENT=$(tmux -L "$POPUP_SOCKET" display-message -p '#{@parent_client}' 2>/dev/null || true)
PARENT_SESSION_ID=$(tmux -L "$POPUP_SOCKET" display-message -p '#{@parent_session_id}' 2>/dev/null || true)
PARENT_WINDOW_ID=$(tmux -L "$POPUP_SOCKET" display-message -p '#{@parent_window_id}' 2>/dev/null || true)

if [ -z "$ACTION" ] || [ -z "$PARENT_SOCKET" ] || [ -z "$PARENT_CLIENT" ] || [ -z "$PARENT_SESSION_ID" ] || [ -z "$PARENT_WINDOW_ID" ]; then
    exit 0
fi

tmux_parent() {
    tmux -S "$PARENT_SOCKET" "$@"
}

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

resolve_parent_client() {
    local session_client=""
    local fallback_client=""

    if tmux_parent display-message -c "$PARENT_CLIENT" -p '#{client_tty}' >/dev/null 2>&1; then
        printf '%s' "$PARENT_CLIENT"
        return 0
    fi

    session_client=$(tmux_parent list-clients -F '#{client_tty} #{session_id}' 2>/dev/null | awk -v sid="$PARENT_SESSION_ID" '$2 == sid { print $1; exit }' || true)
    if [ -n "$session_client" ]; then
        printf '%s' "$session_client"
        return 0
    fi

    fallback_client=$(tmux_parent list-clients -F '#{client_tty}' 2>/dev/null | head -n1 || true)
    printf '%s' "$fallback_client"
    return 0
}

resolve_adjacent_session() {
    local direction="$1"
    local current_session_id=""
    local session_ids=()
    local current_index=-1
    local target_index=0
    local i=0

    current_session_id=$(tmux_parent display-message -c "$TARGET_PARENT_CLIENT" -p '#{session_id}' 2>/dev/null || true)
    if [ -z "$current_session_id" ]; then
        return 0
    fi

    while IFS= read -r session_id; do
        [ -n "$session_id" ] || continue
        session_ids+=("$session_id")
    done < <(tmux_parent list-sessions -F '#{session_id}' 2>/dev/null || true)

    if [ "${#session_ids[@]}" -eq 0 ]; then
        return 0
    fi

    for i in "${!session_ids[@]}"; do
        if [ "${session_ids[$i]}" = "$current_session_id" ]; then
            current_index=$i
            break
        fi
    done

    if [ "$current_index" -lt 0 ]; then
        return 0
    fi

    if [ "$direction" = "prev" ]; then
        target_index=$(( (current_index - 1 + ${#session_ids[@]}) % ${#session_ids[@]} ))
    else
        target_index=$(( (current_index + 1) % ${#session_ids[@]} ))
    fi

    printf '%s' "${session_ids[$target_index]}"
    return 0
}

TARGET_PARENT_CLIENT=$(resolve_parent_client || true)
if [ -z "$TARGET_PARENT_CLIENT" ]; then
    exit 0
fi

CURRENT_PARENT_SESSION_ID=$(tmux_parent display-message -c "$TARGET_PARENT_CLIENT" -p '#{session_id}' 2>/dev/null || printf '%s' "$PARENT_SESSION_ID")
CURRENT_PARENT_WINDOW_ID=$(tmux_parent display-message -c "$TARGET_PARENT_CLIENT" -p '#{window_id}' 2>/dev/null || printf '%s' "$PARENT_WINDOW_ID")

"$STATE_SCRIPT" mark-nav "$PARENT_SOCKET" "$TARGET_PARENT_CLIENT" "$CURRENT_PARENT_SESSION_ID" "$CURRENT_PARENT_WINDOW_ID" || true

case "$ACTION" in
    prev-session)
        detach_popup_client
        TARGET_SESSION_ID=$(resolve_adjacent_session prev || true)
        [ -n "$TARGET_SESSION_ID" ] && tmux_parent switch-client -c "$TARGET_PARENT_CLIENT" -t "=$TARGET_SESSION_ID" 2>/dev/null || true
        ;;
    next-session)
        detach_popup_client
        TARGET_SESSION_ID=$(resolve_adjacent_session next || true)
        [ -n "$TARGET_SESSION_ID" ] && tmux_parent switch-client -c "$TARGET_PARENT_CLIENT" -t "=$TARGET_SESSION_ID" 2>/dev/null || true
        ;;
    prev-window|next-window)
        detach_popup_client
        CURRENT_SESSION=$(tmux_parent display-message -c "$TARGET_PARENT_CLIENT" -p '#{client_session}' 2>/dev/null || true)
        if [ -z "$CURRENT_SESSION" ]; then
            exit 0
        fi
        if [ "$ACTION" = "prev-window" ]; then
            tmux_parent previous-window -t "=$CURRENT_SESSION" 2>/dev/null || true
        else
            tmux_parent next-window -t "=$CURRENT_SESSION" 2>/dev/null || true
        fi
        ;;
    *)
        exit 0
        ;;
esac

exit 0
