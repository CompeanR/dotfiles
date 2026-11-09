#!/usr/bin/env bash
# Silence pi-undo-redo's per-turn "non-git mode" bash warning. Rerun after updating the package.
set -euo pipefail
f="$HOME/.pi/agent/npm/node_modules/pi-undo-redo/src/extension.ts"
python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
new, n = re.subn(r'\n\s*ctx\.ui\.notify\(\s*\n\s*"Pi undo/redo non-git mode only restores[^"]*",\s*\n\s*"warning",\s*\n\s*\);', "", s)
if n: open(p, "w").write(new); print("patched")
else: print("already patched" if "warnedNonGitShell = true" in s else "pattern not found")
PY
