#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_script="$source_dir/vps_screenshot_macos.sh"
target_script="$HOME/scripts/vps_screenshot_macos.sh"
skhd_config="$HOME/.config/skhd/skhdrc"
ssh_key="$HOME/.ssh/id_ed25519_vps_screenshot"
hotkey='ctrl + alt + cmd - 4'

if [[ ! -f $source_script ]]; then
  echo "Missing $source_script; receive both Taildrop files into the same directory." >&2
  exit 1
fi
if [[ ! -f $skhd_config ]]; then
  echo "Missing skhd config: $skhd_config" >&2
  exit 1
fi
if [[ ! -r $ssh_key ]]; then
  echo "Missing screenshot upload key: $ssh_key" >&2
  exit 1
fi

skhd_bin="$(command -v skhd || true)"
if [[ -z $skhd_bin ]]; then
  for candidate in /opt/homebrew/bin/skhd /usr/local/bin/skhd; do
    if [[ -x $candidate ]]; then
      skhd_bin="$candidate"
      break
    fi
  done
fi
if [[ -z $skhd_bin ]]; then
  echo "Could not find skhd." >&2
  exit 1
fi

mkdir -p "$HOME/scripts"
install -m 755 "$source_script" "$target_script"
chmod 600 "$ssh_key"

binding="$hotkey : $target_script"
if grep -Fqx "$binding" "$skhd_config"; then
  echo "VPS screenshot hotkey already configured"
elif grep -Eq '^[[:space:]]*ctrl[[:space:]]*\+[[:space:]]*alt[[:space:]]*\+[[:space:]]*cmd[[:space:]]*-[[:space:]]*4[[:space:]]*:' "$skhd_config"; then
  echo "Refusing to overwrite an existing $hotkey binding in $skhd_config" >&2
  exit 1
else
  backup="$skhd_config.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$skhd_config" "$backup"
  {
    printf '\n# Interactive VPS screenshot: drag a region, or press Space and click a window.\n'
    printf '%s\n' "$binding"
  } >> "$skhd_config"
  echo "Added VPS screenshot hotkey"
  echo "Backup: $backup"
fi

"$skhd_bin" --restart-service
printf '\nInstalled: %s\n' "$target_script"
printf 'Local screenshot:       CMD+SHIFT+4\n'
printf 'VPS screenshot:         CTRL+OPTION+CMD+4\n'
printf 'In the selector, press Space to capture a window.\n'
printf '\nIf macOS prompts for Screen Recording permission, allow skhd and rerun the hotkey.\n'
