#!/usr/bin/env bash
# Last-used workspace toggle (Alt+Tab style): jump to the previously focused space.
# ponytail: no focus-event hook — syncs from live focus on each invoke (single-slot MRU).
set -euo pipefail

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/herdr"
state_file="$state_dir/last-workspace"
mkdir -p "$state_dir"

mapfile -t parsed < <(herdr workspace list | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("{")
if start < 0:
    raise SystemExit("no json from herdr workspace list")
data = json.loads(raw[start:])
workspaces = data.get("result", data).get("workspaces", [])
focused = ""
ids = []
for w in workspaces:
    wid = w.get("workspace_id") or ""
    if not wid:
        continue
    ids.append(wid)
    if w.get("focused"):
        focused = wid
print(focused)
print(" ".join(ids))
')

live="${parsed[0]:-}"
live_ids="${parsed[1]:-}"
if [[ -z "$live" ]]; then
  echo "no focused workspace" >&2
  exit 1
fi

prev=""
curr=""
if [[ -f "$state_file" ]]; then
  # shellcheck disable=SC1090
  source "$state_file" || true
fi

# External navigation (sidebar / shift+alt+[ / picker): treat prior curr as previous.
if [[ -n "${curr:-}" && "$curr" != "$live" ]]; then
  prev="$curr"
fi
curr="$live"

is_live() {
  [[ " $live_ids " == *" $1 "* ]]
}
if [[ -n "$prev" ]] && ! is_live "$prev"; then
  prev=""
fi

if [[ -z "$prev" || "$prev" == "$live" ]]; then
  printf 'prev=%q\ncurr=%q\n' "$prev" "$curr" >"$state_file"
  exit 0
fi

if ! herdr workspace focus "$prev" >/dev/null; then
  printf 'prev=%q\ncurr=%q\n' "" "$curr" >"$state_file"
  exit 1
fi

printf 'prev=%q\ncurr=%q\n' "$live" "$prev" >"$state_file"
