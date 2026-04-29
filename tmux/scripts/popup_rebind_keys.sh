#!/bin/bash
set -euo pipefail

POPUP_SOCKET=${1:?popup socket required}
PARENT_NAV_SCRIPT=${2:?parent nav script required}

shift 2

tmux_popup() {
    tmux -L "$POPUP_SOCKET" "$@"
}

unbind_default_keys() {
    tmux_popup unbind -n C-c 2>/dev/null || true
    tmux_popup unbind -n M-[ 2>/dev/null || true
    tmux_popup unbind -n M-] 2>/dev/null || true
    tmux_popup unbind -n M-{ 2>/dev/null || true
    tmux_popup unbind -n M-} 2>/dev/null || true
    tmux_popup unbind -n PPage 2>/dev/null || true
    tmux_popup unbind -n NPage 2>/dev/null || true
    tmux_popup unbind -n Up 2>/dev/null || true
    tmux_popup unbind -n Down 2>/dev/null || true
    tmux_popup unbind -n M-c 2>/dev/null || true
    tmux_popup unbind -n M-x 2>/dev/null || true
    tmux_popup unbind -n q 2>/dev/null || true
}

unbind_custom_key() {
    local mode=${1:?mode required}
    local key=${2:?key required}

    if [ "$mode" = "root" ]; then
        tmux_popup unbind -n "$key" 2>/dev/null || true
    else
        tmux_popup unbind "$key" 2>/dev/null || true
    fi
}

bind_close_format() {
    local mode=${1:?mode required}
    local key=${2:?key required}

    if [ "$mode" = "root" ]; then
        tmux_popup bind-key -n "$key" run-shell -b '"#{@popup_close_script}" "#{@parent_socket}" "#{@parent_client}" "#{@parent_session_id}" "#{@parent_window_id}" "#{client_tty}"'
    else
        tmux_popup bind-key "$key" run-shell -b '"#{@popup_close_script}" "#{@parent_socket}" "#{@parent_client}" "#{@parent_session_id}" "#{@parent_window_id}" "#{client_tty}"'
    fi
}

bind_close_script() {
    local mode=${1:?mode required}
    local key=${2:?key required}
    local script_path=${3:?script path required}

    if [ "$mode" = "root" ]; then
        tmux_popup bind-key -n "$key" run-shell -b "$script_path"
    else
        tmux_popup bind-key "$key" run-shell -b "$script_path"
    fi
}

unbind_default_keys

# Match the parent tmux copy-mode navigation so h/j/k/l work in popup copy mode.
tmux_popup set-window-option -g mode-keys vi
tmux_popup bind-key -T copy-mode-vi y send -X copy-pipe-and-cancel 'wl-copy'

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bind-format)
            mode=${2:?bind mode required}
            key=${3:?bind key required}
            unbind_custom_key "$mode" "$key"
            bind_close_format "$mode" "$key"
            shift 3
            ;;
        --bind-script)
            mode=${2:?bind mode required}
            key=${3:?bind key required}
            script_path=${4:?script path required}
            unbind_custom_key "$mode" "$key"
            bind_close_script "$mode" "$key" "$script_path"
            shift 4
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

tmux_popup bind-key -n M-[ run-shell -b "$PARENT_NAV_SCRIPT prev-window"
tmux_popup bind-key -n M-] run-shell -b "$PARENT_NAV_SCRIPT next-window"
tmux_popup bind-key -n M-{ run-shell -b "$PARENT_NAV_SCRIPT prev-session"
tmux_popup bind-key -n M-} run-shell -b "$PARENT_NAV_SCRIPT next-session"
tmux_popup bind-key -n PPage if-shell -F '#{==:#{@popup_tool},opencode}' 'if-shell -F "#{pane_in_mode}" "send-keys -X halfpage-up" "send-keys PPage"' 'if-shell -F "#{pane_in_mode}" "send-keys -X halfpage-up" "copy-mode -e; send-keys -X halfpage-up"'
tmux_popup bind-key -n NPage if-shell -F '#{==:#{@popup_tool},opencode}' 'if-shell -F "#{pane_in_mode}" "send-keys -X halfpage-down" "send-keys NPage"' 'if-shell -F "#{pane_in_mode}" "send-keys -X halfpage-down" "copy-mode -e; send-keys -X halfpage-down"'
tmux_popup bind-key -n M-w new-window
tmux_popup bind-key -n M-q kill-pane
tmux_popup bind-key -n M-0 select-window -t 0
tmux_popup bind-key -n M-1 select-window -t 1
tmux_popup bind-key -n M-2 select-window -t 2
tmux_popup bind-key -n M-3 select-window -t 3
tmux_popup bind-key -n M-4 select-window -t 4
tmux_popup bind-key -n M-5 select-window -t 5
tmux_popup bind-key -n M-6 select-window -t 6
tmux_popup bind-key -n M-7 select-window -t 7
tmux_popup bind-key -n M-8 select-window -t 8
tmux_popup bind-key -n M-9 select-window -t 9
