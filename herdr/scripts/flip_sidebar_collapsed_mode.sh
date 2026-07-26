#!/usr/bin/env bash
# Flip ui.sidebar_collapsed_mode between compact (thin rail) and hidden (zero width).
# Used by prefix+shift+b. prefix+b remains Herdr's toggle_sidebar expand/collapse.
set -euo pipefail

cfg="${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
if [[ -L "$cfg" ]]; then
  cfg="$(readlink -f "$cfg")"
fi

if [[ ! -f "$cfg" ]]; then
  echo "herdr config not found: $cfg" >&2
  exit 1
fi

if grep -qE 'sidebar_collapsed_mode[[:space:]]*=[[:space:]]*"hidden"' "$cfg"; then
  new=compact
else
  new=hidden
fi

if grep -qE 'sidebar_collapsed_mode[[:space:]]*=' "$cfg"; then
  sed -i.bak -E "s/sidebar_collapsed_mode[[:space:]]*=[[:space:]]*\"[^\"]*\"/sidebar_collapsed_mode = \"$new\"/" "$cfg"
  rm -f "$cfg.bak"
else
  # Insert under [ui] if missing.
  sed -i.bak -E "/^\[ui\]/a\\
sidebar_collapsed_mode = \"$new\"
" "$cfg"
  rm -f "$cfg.bak"
fi

herdr server reload-config >/dev/null
herdr notification show "Sidebar collapse: $new" --body "compact = thin rail · hidden = fully gone" 2>/dev/null || true
