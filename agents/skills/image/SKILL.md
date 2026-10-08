---
name: image
description: Receive the newest image through Tailscale Taildrop, load it, and analyze it. Use only when the user invokes /image.
argument-hint: "[wait|latest|list] [question]"
disable-model-invocation: true
allowed-tools:
  - Bash(python3 "${CLAUDE_SKILL_DIR}/../../scripts/taildrop-media.py" *)
  - Read
---

# Taildrop image

Receive and analyze an image without asking the user for its local path.

Interpret `$ARGUMENTS` as follows:

- If the first word is `wait`, `latest`, or `list`, use that as the action.
- Otherwise use `receive`; treat all arguments as the user's analysis request.
- Any text after an action is also the analysis request.

Run exactly:

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/taildrop-media.py" image ACTION
```

For `list`, show the returned paths and stop. Otherwise stdout contains one absolute image path. Read that image with the Read tool, then answer the user's request. If no request was supplied, briefly describe the image and transcribe important visible text.

Do not modify or delete the received image. If receipt or reading fails, report the exact error and the expected upload directory instead of guessing about the image.
