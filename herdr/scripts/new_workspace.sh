#!/usr/bin/env bash
# New Space in the calling pane's cwd, prompting for the Space name and its first
# tab name. Empty answers keep Herdr's generated names; ctrl+c cancels.
set -euo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"

read -r -e -p "Space name: " space_name
read -r -e -p "Tab name: " tab_name

args=(workspace create --cwd "$PWD" --focus)
[[ -n "$space_name" ]] && args+=(--label "$space_name")

tab_id="$("$herdr_bin" "${args[@]}" | jq -r '.result.tab.tab_id')"
[[ -n "$tab_name" ]] && "$herdr_bin" tab rename "$tab_id" "$tab_name" >/dev/null
exit 0
