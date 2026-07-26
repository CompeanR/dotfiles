#!/bin/bash
set -euo pipefail

bindings="$HOME/.config/hypr/bindings.lua"
vps_script="$HOME/scripts/vps_screenshot.sh"

if [[ ! -f $bindings ]]; then
  echo "Missing Omarchy bindings file: $bindings" >&2
  exit 1
fi
if [[ ! -x $vps_script ]]; then
  echo "Missing executable VPS screenshot script: $vps_script" >&2
  exit 1
fi

backup="$bindings.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$bindings" "$backup"

python3 - "$bindings" "$vps_script" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
vps_script = sys.argv[2]
text = path.read_text()
local_key = "CTRL + SHIFT + 4"
vps_key = "SUPER + CTRL + SHIFT + 4"
local_command = "hyprshot -m window -m active --clipboard-only -o /home/compean/Pictures/Screenshots"
new_block = "\n".join([
    f'hl.unbind("{local_key}")',
    f'o.bind("{local_key}", "Screenshot active window", "{local_command}")',
    f'hl.unbind("{vps_key}")',
    f'o.bind("{vps_key}", "Screenshot active window to VPS", "{vps_script}")',
])

if new_block in text:
    print("Local/VPS screenshot bindings already configured")
    raise SystemExit(0)

# Replace the currently installed local-key VPS block. The preceding unbind is
# included so rerunning the installer remains idempotent.
pattern = re.compile(
    rf'^\s*hl\.unbind\("{re.escape(local_key)}"\)\s*\n'
    rf'\s*o\.bind\("{re.escape(local_key)}",\s*"Screenshot active window to VPS",.*\)\s*$',
    re.MULTILINE,
)
updated, count = pattern.subn(new_block, text)
if count != 1:
    raise SystemExit(f"Expected one current VPS screenshot binding block, found {count}")
path.write_text(updated)
print(f"Configured {local_key} for local capture")
print(f"Configured {vps_key} for VPS capture")
PY

hyprctl reload
printf '\nHyprland config errors (empty is good):\n'
hyprctl configerrors || true
printf '\nBackup: %s\n' "$backup"
printf 'Local screenshot: CTRL+SHIFT+4\n'
printf 'VPS screenshot:   SUPER+CTRL+SHIFT+4\n'
