#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_SCRIPT="$SCRIPT_DIR/popup_state.sh"
POPUP_SOCKET="popup-hub"

SOCKET_PATH="${1:-}"
HOOK_CLIENT="${2:-}"
CURRENT_CLIENT="${3:-}"
SESSION_ID="${4:-}"
WINDOW_ID="${5:-}"
SCRIPTS_DIR_ARG="${6:-}"
CLIENT_TTY="${HOOK_CLIENT:-$CURRENT_CLIENT}"
SCRIPTS_DIR="${SCRIPTS_DIR_ARG:-$SCRIPT_DIR}"

tmux_outer() {
    tmux -S "$SOCKET_PATH" "$@"
}

resolve_from_client() {
    tmux_outer display-message -c "$CLIENT_TTY" -p "$1" 2>/dev/null || true
}

if [ -z "$SOCKET_PATH" ] || [ -z "$CLIENT_TTY" ]; then
    exit 0
fi

CLIENT_SESSION_ID=$(resolve_from_client '#{session_id}')
CLIENT_WINDOW_ID=$(resolve_from_client '#{window_id}')

if [[ "$CLIENT_SESSION_ID" =~ ^\$[0-9]+$ ]]; then
    SESSION_ID="$CLIENT_SESSION_ID"
elif [[ ! "$SESSION_ID" =~ ^\$[0-9]+$ ]]; then
    SESSION_ID=""
fi

if [[ "$CLIENT_WINDOW_ID" =~ ^@[0-9]+$ ]]; then
    WINDOW_ID="$CLIENT_WINDOW_ID"
elif [[ ! "$WINDOW_ID" =~ ^@[0-9]+$ ]]; then
    WINDOW_ID=""
fi

if [ -z "$SESSION_ID" ] || [ -z "$WINDOW_ID" ]; then
    exit 0
fi

TOOL=$("$STATE_SCRIPT" get-tool "$SOCKET_PATH" "$CLIENT_TTY" "$SESSION_ID" "$WINDOW_ID")
if [ -z "$TOOL" ]; then
    exit 0
fi

POPUP_SESSION="${TOOL}_popup_${WINDOW_ID}"
if ! tmux -L "$POPUP_SOCKET" has-session -t "$POPUP_SESSION" 2>/dev/null; then
    "$STATE_SCRIPT" clear-tool "$SOCKET_PATH" "$CLIENT_TTY" "$SESSION_ID" "$WINDOW_ID"
    "$STATE_SCRIPT" clear-nav "$SOCKET_PATH" "$CLIENT_TTY" "$SESSION_ID" "$WINDOW_ID"
    exit 0
fi

case "$TOOL" in
    codex|terminal|claude|opencode|lazydocker)
        exec "$SCRIPTS_DIR/${TOOL}_toggle.sh" --restore --socket-path "$SOCKET_PATH" --client-tty "$CLIENT_TTY" --session-id "$SESSION_ID" --window-id "$WINDOW_ID"
        ;;
    *)
        exit 0
        ;;
esac
