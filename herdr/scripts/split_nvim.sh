#!/usr/bin/env bash
# Split the focused pane to the right and open nvim in the new pane, zoomed.
set -euo pipefail

herdr_bin="$(command -v herdr 2>/dev/null || true)"
for candidate in "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do
  [[ -n "$herdr_bin" ]] && break
  [[ -x "$candidate" ]] && herdr_bin="$candidate"
done

pane_id="$("$herdr_bin" pane split --direction right --focus | jq -r '.result.pane.pane_id')"
"$herdr_bin" pane zoom "$pane_id" --on
"$herdr_bin" pane run "$pane_id" nvim
