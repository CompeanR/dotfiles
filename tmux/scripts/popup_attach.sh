#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_SCRIPT="$SCRIPT_DIR/popup_state.sh"

POPUP_SOCKET="${1:-}"
POPUP_SESSION="${2:-}"
PARENT_SOCKET="${3:-}"
PARENT_CLIENT="${4:-}"
PARENT_SESSION_ID="${5:-}"
PARENT_WINDOW_ID="${6:-}"
TOOL="${7:-}"

if [ -z "$POPUP_SOCKET" ] || [ -z "$POPUP_SESSION" ] || [ -z "$PARENT_SOCKET" ] || [ -z "$PARENT_CLIENT" ] || [ -z "$PARENT_SESSION_ID" ] || [ -z "$PARENT_WINDOW_ID" ] || [ -z "$TOOL" ]; then
    exit 1
fi

tmux -L "$POPUP_SOCKET" attach -t "$POPUP_SESSION"

NAV_PENDING=$("$STATE_SCRIPT" get-nav "$PARENT_SOCKET" "$PARENT_CLIENT" "$PARENT_SESSION_ID" "$PARENT_WINDOW_ID")
if [ "$NAV_PENDING" = "1" ]; then
    "$STATE_SCRIPT" clear-nav "$PARENT_SOCKET" "$PARENT_CLIENT" "$PARENT_SESSION_ID" "$PARENT_WINDOW_ID"
fi
