#!/usr/bin/env bash
# Last-used workspace toggle (Alt+Tab style): jump to the previously focused space.
# ponytail: no focus-event hook — syncs from live focus on each invoke (single-slot MRU).
set -euo pipefail

herdr_bin="${HERDR_BIN:-}"
if [[ -z "$herdr_bin" ]]; then
  candidate="$(command -v herdr 2>/dev/null || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    herdr_bin="$candidate"
  else
    for candidate in "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do
      if [[ -x "$candidate" ]]; then
        herdr_bin="$candidate"
        break
      fi
    done
  fi
fi
if [[ -z "$herdr_bin" || ! -x "$herdr_bin" ]]; then
  echo "herdr executable not found" >&2
  exit 1
fi

python_bin="$(command -v python3 2>/dev/null || true)"
if [[ -z "$python_bin" || ! -x "$python_bin" ]]; then
  python_bin=/usr/bin/python3
fi
if [[ ! -x "$python_bin" ]]; then
  echo "python3 executable not found" >&2
  exit 1
fi

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/herdr"
state_file="$state_dir/last-workspace"
mkdir -p "$state_dir"

if ! parsed="$("$herdr_bin" workspace list | "$python_bin" -c '
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
')"; then
  echo "failed to list herdr workspaces" >&2
  exit 1
fi

live="${parsed%%$'\n'*}"
live_ids=""
if [[ "$parsed" == *$'\n'* ]]; then
  live_ids="${parsed#*$'\n'}"
  live_ids="${live_ids%%$'\n'*}"
fi
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

if ! "$herdr_bin" workspace focus "$prev" >/dev/null; then
  printf 'prev=%q\ncurr=%q\n' "" "$curr" >"$state_file"
  exit 1
fi

printf 'prev=%q\ncurr=%q\n' "$live" "$prev" >"$state_file"
