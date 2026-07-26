#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_script="$source_dir/vps_screenshot.sh"
target_script="$HOME/scripts/vps_screenshot.sh"
bindings="$HOME/.config/hypr/bindings.lua"

if [[ ! -f $source_script ]]; then
  echo "Missing $source_script; receive both Taildrop files into the same directory." >&2
  exit 1
fi
if [[ ! -f $bindings ]]; then
  echo "Missing Omarchy bindings file: $bindings" >&2
  exit 1
fi
for dependency in grim hyprctl jq ssh wl-copy python3; do
  command -v "$dependency" >/dev/null 2>&1 || {
    echo "Missing required command: $dependency" >&2
    exit 1
  }
done

mkdir -p "$HOME/scripts"
install -m 755 "$source_script" "$target_script"
backup="$bindings.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$bindings" "$backup"

python3 - "$bindings" "$target_script" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
script = sys.argv[2]
text = path.read_text()
replacement = f'o.bind("CTRL + SHIFT + 4", "Screenshot active window to VPS", "{script}")'
if replacement in text:
    print("Screenshot binding already configured")
    raise SystemExit(0)
pattern = re.compile(
    r'^\s*o\.bind\("CTRL \+ SHIFT \+ 4",\s*"Screenshot active window",.*\)\s*$',
    re.MULTILINE,
)
updated, count = pattern.subn(replacement, text)
if count != 1:
    raise SystemExit(f"Expected one active-window screenshot binding, found {count}")
path.write_text(updated)
print("Updated CTRL+SHIFT+4 screenshot binding")
PY

hyprctl reload
printf '\nHyprland config errors (empty is good):\n'
hyprctl configerrors || true
printf '\nInstalled: %s\nBackup: %s\n' "$target_script" "$backup"
printf 'CTRL+SHIFT+4 now captures, uploads to dev-vps, and copies the VPS path.\n'
