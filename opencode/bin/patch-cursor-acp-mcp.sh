#!/usr/bin/env bash
# Re-apply after: npm update -g @rama_nigg/open-cursor
# Lets OpenCode's mcp-shim intercept Composer's generic `mcp` meta-tool calls.
set -euo pipefail

PKG="$(npm root -g)/@rama_nigg/open-cursor"
OLD='if (name.toLowerCase() === "mcp") {'
NEW='if (name.toLowerCase() === "mcp" && !resolveAllowedToolName(name, allowedToolNames)) {'

for file in "$PKG/dist/plugin-entry.js" "$PKG/dist/index.js"; do
  if [[ ! -f "$file" ]]; then
    echo "skip (missing): $file" >&2
    continue
  fi
  if grep -qF "$NEW" "$file"; then
    echo "already patched: $file"
    continue
  fi
  if ! grep -qF "$OLD" "$file"; then
    echo "pattern not found (package may have changed): $file" >&2
    continue
  fi
  sed -i '' "s/$(printf '%s' "$OLD" | sed 's/[\/&]/\\&/g')/$(printf '%s' "$NEW" | sed 's/[\/&]/\\&/g')/" "$file"
  echo "patched: $file"
done

SRC="$PKG/src/proxy/tool-loop.ts"
if [[ -f "$SRC" ]] && grep -qF 'if (name.toLowerCase() === "mcp") {' "$SRC" && ! grep -qF 'resolveAllowedToolName(name, allowedToolNames)' "$SRC"; then
  echo "note: patch src/proxy/tool-loop.ts manually if you rebuild open-cursor from source" >&2
fi
