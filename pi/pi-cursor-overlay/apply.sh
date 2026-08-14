#!/usr/bin/env bash
# Re-apply after replacing ~/.pi/agent/src/pi-cursor:
#   pi/pi-cursor-overlay/apply.sh
#
# Overlay baseline: Rahularya01/pi-cursor 7df0085 (1.4.9).
# pi update --extensions does not touch this local src/ tree; this script is
# for a manual copy/upgrade of that checkout.
set -euo pipefail

OVERLAY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$OVERLAY/subagent.patch"
TARGET="${1:-$HOME/.pi/agent/src/pi-cursor}"

MARKER_SLIM='Never set model or thinking in the tool arguments'
MARKER_REJECT='Cursor-native Task is unavailable'

if [[ ! -f "$PATCH" ]]; then
  echo "missing patch: $PATCH" >&2
  exit 1
fi
if [[ ! -f "$TARGET/package.json" ]]; then
  echo "no pi-cursor at $TARGET" >&2
  exit 1
fi

name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$TARGET/package.json")"
if [[ "$name" != "@rahularya01/pi-cursor" ]]; then
  echo "refusing: $TARGET is $name, not @rahularya01/pi-cursor" >&2
  exit 1
fi

src_applied() {
  [[ -f "$TARGET/src/stream/request-build.ts" && -f "$TARGET/src/stream/server-messages.ts" ]] \
    && grep -Fq "$MARKER_SLIM" "$TARGET/src/stream/request-build.ts" \
    && grep -Fq "$MARKER_REJECT" "$TARGET/src/stream/server-messages.ts"
}

dist_applied() {
  [[ -f "$TARGET/dist/index.js" ]] \
    && grep -Fq "$MARKER_SLIM" "$TARGET/dist/index.js" \
    && grep -Fq "$MARKER_REJECT" "$TARGET/dist/index.js"
}

rebuild() {
  if [[ ! -d "$TARGET/node_modules/tsup" || ! -d "$TARGET/node_modules/@bufbuild/buf" ]]; then
    echo "overlay source is in place but dist needs a rebuild; in $TARGET run:" >&2
    echo "  npm install && npm run proto:gen && npm run build" >&2
    exit 1
  fi
  (cd "$TARGET" && npm run proto:gen && npm run build)
  if ! dist_applied; then
    echo "rebuild finished but dist is missing overlay markers" >&2
    exit 1
  fi
}

if src_applied; then
  if dist_applied; then
    echo "already applied: $TARGET"
    exit 0
  fi
  echo "source overlay present; rebuilding dist"
  rebuild
  echo "rebuilt: $TARGET"
  exit 0
fi

(cd "$TARGET" && git apply -p1 "$PATCH")
rebuild
echo "applied: $TARGET"
