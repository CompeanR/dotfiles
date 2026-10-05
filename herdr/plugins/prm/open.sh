#!/usr/bin/env bash
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
pane="${HERDR_PANE_ID:-}"

if [ -n "$pane" ] && "$herdr" pane process-info --pane "$pane" 2>/dev/null \
  | jq -e '.result.process_info.foreground_processes[]?.name | ascii_downcase | test("^n?vim$")' >/dev/null; then
  exec "$herdr" pane send-keys "$pane" alt+r
fi

cwd=""
if [ -n "$pane" ]; then
  cwd=$("$herdr" pane get "$pane" 2>/dev/null | jq -r '.result.pane.foreground_cwd // .result.pane.cwd // empty')
fi

exec "$herdr" plugin pane open --plugin prm --entrypoint tui --placement popup --width 90% --height 90% ${cwd:+--cwd "$cwd"}
