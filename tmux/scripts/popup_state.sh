#!/bin/bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
COMMAND="${1:-}"
SOCKET_PATH="${2:-}"
CLIENT_TTY="${3:-}"
SESSION_ID="${4:-}"
WINDOW_ID="${5:-}"
VALUE="${6:-}"

if [ -z "$COMMAND" ] || [ -z "$SOCKET_PATH" ] || [ -z "$CLIENT_TTY" ] || [ -z "$SESSION_ID" ] || [ -z "$WINDOW_ID" ]; then
    exit 1
fi

sanitize() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'
}

state_key() {
    printf '%s__%s__%s' "$(sanitize "$CLIENT_TTY")" "$(sanitize "$SESSION_ID")" "$(sanitize "$WINDOW_ID")"
}

KEY=$(state_key)
TOOL_OPTION="@popup_tool_${KEY}"
NAV_OPTION="@popup_nav_${KEY}"

tmux_outer() {
    tmux -S "$SOCKET_PATH" "$@"
}

get_option() {
    tmux_outer show-options -gqv "$1" 2>/dev/null || true
}

clear_client_options() {
    local client_prefix
    client_prefix="$(sanitize "$CLIENT_TTY")"

    tmux_outer show-options -g 2>/dev/null \
        | awk -v prefix="$client_prefix" '
            index($1, "@popup_tool_" prefix "__") == 1 { print $1 }
            index($1, "@popup_nav_" prefix "__") == 1 { print $1 }
        ' \
        | while IFS= read -r option_name; do
            [ -n "$option_name" ] || continue
            tmux_outer set-option -guq "$option_name" 2>/dev/null || true
        done
}

case "$COMMAND" in
    set-tool)
        if [ -z "$VALUE" ]; then
            exit 1
        fi
        tmux_outer set-option -gq "$TOOL_OPTION" "$VALUE"
        ;;
    get-tool)
        get_option "$TOOL_OPTION"
        ;;
    clear-tool)
        tmux_outer set-option -guq "$TOOL_OPTION"
        ;;
    mark-nav)
        tmux_outer set-option -gq "$NAV_OPTION" 1
        ;;
    get-nav)
        get_option "$NAV_OPTION"
        ;;
    clear-nav)
        tmux_outer set-option -guq "$NAV_OPTION"
        ;;
    clear-client)
        clear_client_options
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        exit 1
        ;;
esac
