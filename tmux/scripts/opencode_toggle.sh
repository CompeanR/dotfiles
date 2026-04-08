#!/bin/bash
set -euo pipefail

# Opencode popup toggle using session name detection (window-specific)
TOOL="opencode"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
POPUP_STATE_SCRIPT="$SCRIPT_DIR/popup_state.sh"
POPUP_CLOSE_SCRIPT="$SCRIPT_DIR/popup_close.sh"
POPUP_ATTACH_SCRIPT="$SCRIPT_DIR/popup_attach.sh"
POPUP_SYNC_ENV_SCRIPT="$SCRIPT_DIR/popup_sync_env.sh"
PARENT_NAV_SCRIPT="$SCRIPT_DIR/popup_parent_nav.sh"
POPUP_REBIND_SCRIPT="$SCRIPT_DIR/popup_rebind_keys.sh"
POPUP_SOCKET="popup-hub"
RESTORE_MODE=0
CURRENT_DIR_ARG=""
PARENT_CLIENT=""
PARENT_SOCKET=""
PARENT_SESSION_ID=""
PARENT_WINDOW_ID=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --restore)
            RESTORE_MODE=1
            shift
            ;;
        --client-tty)
            PARENT_CLIENT="${2:-}"
            shift 2
            ;;
        --socket-path)
            PARENT_SOCKET="${2:-}"
            shift 2
            ;;
        --session-id)
            PARENT_SESSION_ID="${2:-}"
            shift 2
            ;;
        --window-id)
            PARENT_WINDOW_ID="${2:-}"
            shift 2
            ;;
        *)
            if [ -z "$CURRENT_DIR_ARG" ]; then
                CURRENT_DIR_ARG="$1"
            fi
            shift
            ;;
    esac
done

tmux_parent() {
    if [ -n "$PARENT_SOCKET" ]; then
        tmux -S "$PARENT_SOCKET" "$@"
    else
        tmux "$@"
    fi
}

if [ -z "$PARENT_SOCKET" ]; then
    PARENT_SOCKET=$(tmux display-message -p '#{socket_path}')
fi
if [ -z "$PARENT_CLIENT" ]; then
    PARENT_CLIENT=$(tmux_parent display-message -p '#{client_tty}')
fi
if [ -z "$PARENT_SESSION_ID" ]; then
    PARENT_SESSION_ID=$(tmux_parent display-message -c "$PARENT_CLIENT" -p '#{session_id}')
fi
if [ -z "$PARENT_WINDOW_ID" ]; then
    PARENT_WINDOW_ID=$(tmux_parent display-message -c "$PARENT_CLIENT" -p '#{window_id}')
fi
if [ -z "$CURRENT_DIR_ARG" ]; then
    CURRENT_DIR=$(tmux_parent display-message -c "$PARENT_CLIENT" -p '#{pane_current_path}' 2>/dev/null || printf '%s' "$PWD")
else
    CURRENT_DIR="$CURRENT_DIR_ARG"
fi

POPUP_ENV_ARGS=()
while IFS= read -r env_line; do
    if [ -n "$env_line" ]; then
        POPUP_ENV_ARGS+=(-e "$env_line")
    fi
done < <("$POPUP_SYNC_ENV_SCRIPT" "$PARENT_SOCKET")

PARENT_TERM=$(tmux_parent show-environment -g TERM 2>/dev/null || true)
if [ -z "$PARENT_TERM" ] || [ "$PARENT_TERM" = "-TERM" ]; then
    PARENT_TERM="tmux-256color"
else
    PARENT_TERM=${PARENT_TERM#TERM=}
fi

PARENT_COLORTERM=$(tmux_parent show-environment -g COLORTERM 2>/dev/null || true)
if [ -z "$PARENT_COLORTERM" ] || [ "$PARENT_COLORTERM" = "-COLORTERM" ]; then
    PARENT_COLORTERM="truecolor"
else
    PARENT_COLORTERM=${PARENT_COLORTERM#COLORTERM=}
fi

WINDOW_ID="$PARENT_WINDOW_ID"
POPUP_SESSION="${TOOL}_popup_${WINDOW_ID}"

if [ "$RESTORE_MODE" -eq 0 ]; then
    CURRENT_SESSION=$(tmux_parent display-message -c "$PARENT_CLIENT" -p '#S' 2>/dev/null || true)
    if echo "$CURRENT_SESSION" | grep -q "^${TOOL}_popup_"; then
        tmux detach-client
        exit 0
    fi
fi

if tmux -L "$POPUP_SOCKET" list-clients -t "$POPUP_SESSION" 2>/dev/null | grep -q .; then
    exit 0
fi

if ! tmux -L "$POPUP_SOCKET" has-session -t "$POPUP_SESSION" 2>/dev/null; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        tmux -L "$POPUP_SOCKET" -f /dev/null new-session "${POPUP_ENV_ARGS[@]}" -d -s "$POPUP_SESSION" -c "$CURRENT_DIR" "cd '$CURRENT_DIR' && while true; do opencode -c || opencode; done"
    else
        tmux -L "$POPUP_SOCKET" -f /dev/null new-session "${POPUP_ENV_ARGS[@]}" -d -s "$POPUP_SESSION" -c "$CURRENT_DIR" "source ~/.zshrc && cd '$CURRENT_DIR' && while true; do opencode -c || opencode; done"
    fi
    tmux -L "$POPUP_SOCKET" set-option -s -t "$POPUP_SESSION" status off
    tmux -L "$POPUP_SOCKET" set -g prefix C-c
    tmux -L "$POPUP_SOCKET" unbind C-b
    tmux -L "$POPUP_SOCKET" bind C-c send-prefix
    tmux -L "$POPUP_SOCKET" set -g @scripts_dir "$SCRIPT_DIR"
fi

if [ "$RESTORE_MODE" -eq 0 ]; then
    "$POPUP_STATE_SCRIPT" clear-client "$PARENT_SOCKET" "$PARENT_CLIENT" "$PARENT_SESSION_ID" "$PARENT_WINDOW_ID" || true
fi

"$POPUP_STATE_SCRIPT" set-tool "$PARENT_SOCKET" "$PARENT_CLIENT" "$PARENT_SESSION_ID" "$PARENT_WINDOW_ID" "$TOOL"
"$POPUP_STATE_SCRIPT" clear-nav "$PARENT_SOCKET" "$PARENT_CLIENT" "$PARENT_SESSION_ID" "$PARENT_WINDOW_ID"

tmux -L "$POPUP_SOCKET" set-option -q -t "$POPUP_SESSION" @parent_socket "$PARENT_SOCKET"
tmux -L "$POPUP_SOCKET" set-option -q -t "$POPUP_SESSION" @parent_client "$PARENT_CLIENT"
tmux -L "$POPUP_SOCKET" set-option -q -t "$POPUP_SESSION" @parent_session_id "$PARENT_SESSION_ID"
tmux -L "$POPUP_SOCKET" set-option -q -t "$POPUP_SESSION" @parent_window_id "$PARENT_WINDOW_ID"
tmux -L "$POPUP_SOCKET" set-option -q -t "$POPUP_SESSION" @popup_tool "$TOOL"
tmux -L "$POPUP_SOCKET" set-option -q -t "$POPUP_SESSION" @popup_close_script "$POPUP_CLOSE_SCRIPT"
tmux -L "$POPUP_SOCKET" set-option -q -t "$POPUP_SESSION" @parent_nav_script "$PARENT_NAV_SCRIPT"

"$POPUP_REBIND_SCRIPT" "$POPUP_SOCKET" "$PARENT_NAV_SCRIPT" --bind-format root M-p

printf -v ATTACH_CMD '%q ' env "TERM=$PARENT_TERM" "COLORTERM=$PARENT_COLORTERM" "$POPUP_ATTACH_SCRIPT" "$POPUP_SOCKET" "$POPUP_SESSION" "$PARENT_SOCKET" "$PARENT_CLIENT" "$PARENT_SESSION_ID" "$PARENT_WINDOW_ID" "$TOOL"
ATTACH_CMD=${ATTACH_CMD% }

WIDTH="75%"
HEIGHT="90%"

tmux_parent display-popup -c "$PARENT_CLIENT" -xC -yC -w "$WIDTH" -h "$HEIGHT" -d "$CURRENT_DIR" -E "$ATTACH_CMD"
