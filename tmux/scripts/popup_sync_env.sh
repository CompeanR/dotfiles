#!/bin/bash
set -euo pipefail

PARENT_SOCKET="${1:-}"

tmux_parent() {
    if [ -n "$PARENT_SOCKET" ]; then
        tmux -S "$PARENT_SOCKET" "$@"
    else
        tmux "$@"
    fi
}

while IFS= read -r line; do
    if [ -z "$line" ]; then
        continue
    fi

    if [[ "$line" == -* ]]; then
        continue
    fi

    printf '%s\n' "$line"
done < <(tmux_parent show-environment -g 2>/dev/null || true)
