#!/usr/bin/env bash
# New Space in the calling pane's cwd, prompting for its first tab name. An empty
# answer keeps Herdr's generated name; ctrl+c cancels.
set -euo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"

read -r -e -p "Tab name: " tab_name

tab_id="$("$herdr_bin" workspace create --cwd "$PWD" --focus | jq -r '.result.tab.tab_id')"
[[ -n "$tab_name" ]] && "$herdr_bin" tab rename "$tab_id" "$tab_name" >/dev/null
exit 0
