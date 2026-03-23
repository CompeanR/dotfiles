#!/usr/bin/env bash
set -euo pipefail
SRC="$HOME/.codex/skills/prd-workflow"
DST="$HOME/.config/opencode/skills/prd-workflow"
CMD_DIR="$HOME/.config/opencode/commands"
mkdir -p "$DST" "$CMD_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "$SRC/" "$DST/"
else
  rm -rf "$DST"
  mkdir -p "$DST"
  cp -R "$SRC/." "$DST/"
fi
hash_tree() {
  local dir="$1"
  (
    cd "$dir"
    find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
  )
}
sha_src=$(hash_tree "$SRC")
sha_dst=$(hash_tree "$DST")
[ "$sha_src" = "$sha_dst" ] || { echo "checksum mismatch"; exit 1; }
echo "sync ok"
