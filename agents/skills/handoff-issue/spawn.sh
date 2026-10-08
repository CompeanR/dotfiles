#!/usr/bin/env bash
# Usage: spawn.sh <dir> <tab-label> <agent-name> <prompt-file>
# Opens a tab for <dir> (reusing its herdr workspace, or creating one), starts pi there and sends the prompt.
set -euo pipefail

dir=$(cd "$1" && pwd)
label=$2
name=$3
prompt=$(cat "$4")
workspace_label=$(basename "$dir")

# Reuse the sidebar workspace named after the project, or one with a pane already in it.
ws=$(herdr workspace list | jq -r --arg l "$workspace_label" \
  'first(.result.workspaces[] | select(.label | ascii_downcase == ($l | ascii_downcase)) | .workspace_id) // empty')
if [ -z "$ws" ]; then
  ws=$(herdr pane list | jq -r --arg d "$dir" \
    'first(.result.panes[] | select(.cwd == $d or (.cwd | startswith($d + "/"))) | .workspace_id) // empty')
fi

if [ -n "$ws" ]; then
  out=$(herdr tab create --workspace "$ws" --cwd "$dir" --label "$label" --no-focus)
else
  out=$(herdr workspace create --cwd "$dir" --label "$workspace_label" --no-focus)
  ws=$(jq -r '.result.workspace.workspace_id' <<<"$out")
  herdr tab rename "$(jq -r '.result.tab.tab_id' <<<"$out")" "$label" >/dev/null
fi

pane=$(jq -r '.result.root_pane.pane_id' <<<"$out")
herdr agent start "$name" --kind pi --pane "$pane" --timeout 60000 >/dev/null
herdr agent prompt "$name" "$prompt" >/dev/null

echo "workspace=$ws pane=$pane agent=$name"
