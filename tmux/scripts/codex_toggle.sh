#!/bin/bash
set -euo pipefail

# Codex popup toggle using session name detection (window-specific)
TOOL="codex"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
POPUP_STATE_SCRIPT="$SCRIPT_DIR/popup_state.sh"
POPUP_CLOSE_SCRIPT="$SCRIPT_DIR/popup_close.sh"
POPUP_ATTACH_SCRIPT="$SCRIPT_DIR/popup_attach.sh"
PARENT_NAV_SCRIPT="$SCRIPT_DIR/popup_parent_nav.sh"
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
    if command -v codex >/dev/null 2>&1; then
        CODEX_BIN=$(command -v codex)
    else
        CODEX_BIN="/home/compean/.nvm/versions/node/v22.17.1/bin/codex"
    fi

    if [[ "$OSTYPE" == "darwin"* ]]; then
        CODEX_ARGS=(--full-auto)
    else
        CODEX_ARGS=(--dangerously-bypass-approvals-and-sandbox)
    fi

    printf -v CODEX_CMD '%q ' "$CODEX_BIN" "${CODEX_ARGS[@]}"
    CODEX_CMD=${CODEX_CMD% }
    printf -v CURRENT_DIR_QUOTED '%q' "$CURRENT_DIR"

    tmux -L "$POPUP_SOCKET" -f /dev/null new-session -d -s "$POPUP_SESSION" -c "$CURRENT_DIR" "if [ -f \"\$HOME/.zshrc\" ]; then source \"\$HOME/.zshrc\"; fi; cd -- $CURRENT_DIR_QUOTED && while true; do $CODEX_CMD; done"
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

tmux -L "$POPUP_SOCKET" unbind -n C-c 2>/dev/null
tmux -L "$POPUP_SOCKET" unbind -n M-[ 2>/dev/null
tmux -L "$POPUP_SOCKET" unbind -n M-] 2>/dev/null
tmux -L "$POPUP_SOCKET" unbind -n M-{ 2>/dev/null
tmux -L "$POPUP_SOCKET" unbind -n M-} 2>/dev/null
tmux -L "$POPUP_SOCKET" unbind -n M-o 2>/dev/null
tmux -L "$POPUP_SOCKET" bind-key -n M-o run-shell -b "$POPUP_CLOSE_SCRIPT"
tmux -L "$POPUP_SOCKET" bind-key -n M-[ run-shell -b "$PARENT_NAV_SCRIPT prev-window"
tmux -L "$POPUP_SOCKET" bind-key -n M-] run-shell -b "$PARENT_NAV_SCRIPT next-window"
tmux -L "$POPUP_SOCKET" bind-key -n M-{ run-shell -b "$PARENT_NAV_SCRIPT prev-session"
tmux -L "$POPUP_SOCKET" bind-key -n M-} run-shell -b "$PARENT_NAV_SCRIPT next-session"

tmux -L "$POPUP_SOCKET" unbind -n M-c 2>/dev/null
tmux -L "$POPUP_SOCKET" unbind -n M-x 2>/dev/null
tmux -L "$POPUP_SOCKET" bind-key -n M-w new-window
tmux -L "$POPUP_SOCKET" bind-key -n M-q kill-pane
tmux -L "$POPUP_SOCKET" bind-key -n M-0 select-window -t 0
tmux -L "$POPUP_SOCKET" bind-key -n M-1 select-window -t 1
tmux -L "$POPUP_SOCKET" bind-key -n M-2 select-window -t 2
tmux -L "$POPUP_SOCKET" bind-key -n M-3 select-window -t 3
tmux -L "$POPUP_SOCKET" bind-key -n M-4 select-window -t 4
tmux -L "$POPUP_SOCKET" bind-key -n M-5 select-window -t 5
tmux -L "$POPUP_SOCKET" bind-key -n M-6 select-window -t 6
tmux -L "$POPUP_SOCKET" bind-key -n M-7 select-window -t 7
tmux -L "$POPUP_SOCKET" bind-key -n M-8 select-window -t 8
tmux -L "$POPUP_SOCKET" bind-key -n M-9 select-window -t 9

printf -v ATTACH_CMD '%q ' "$POPUP_ATTACH_SCRIPT" "$POPUP_SOCKET" "$POPUP_SESSION" "$PARENT_SOCKET" "$PARENT_CLIENT" "$PARENT_SESSION_ID" "$PARENT_WINDOW_ID" "$TOOL"
ATTACH_CMD=${ATTACH_CMD% }

TERM_WIDTH=$(tmux_parent display-message -c "$PARENT_CLIENT" -p '#{client_width}' 2>/dev/null || echo 200)
if [ "$TERM_WIDTH" -gt 200 ]; then
    WIDTH="70%"
    HEIGHT="90%"
else
    WIDTH="85%"
    HEIGHT="95%"
fi

tmux_parent display-popup -c "$PARENT_CLIENT" -xC -yC -w "$WIDTH" -h "$HEIGHT" -d "$CURRENT_DIR" -E "TERM=xterm-256color $ATTACH_CMD"
