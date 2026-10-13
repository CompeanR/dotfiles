---
name: push
description: "Moshi push alerts for Claude: /push on|off|next|cancel|status"
disable-model-invocation: true
allowed-tools:
  - Bash(python3 ~/.claude/hooks/moshi-alert.py *)
---

!`python3 ~/.claude/hooks/moshi-alert.py status $ARGUMENTS`

Reply with the output above, nothing else.
