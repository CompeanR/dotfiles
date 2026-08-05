---
name: video
description: Receive the newest video through Tailscale Taildrop, extract representative frames with ffmpeg, and analyze its visual content. Use only when the user invokes /video.
argument-hint: "[wait|latest|list] [question]"
disable-model-invocation: true
allowed-tools:
  - Bash(python3 "${CLAUDE_SKILL_DIR}/../../scripts/taildrop-media.py" *)
  - Bash(python3 "${CLAUDE_SKILL_DIR}/../../scripts/extract-video-frames.py" *)
  - Read
---

# Taildrop video

Receive and visually analyze a video without asking the user for its local path.

Interpret `$ARGUMENTS` as follows:

- If the first word is `wait`, `latest`, or `list`, use that as the action.
- Otherwise use `receive`; treat all arguments as the user's analysis request.
- Any text after an action is also the analysis request.

Run exactly:

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/taildrop-media.py" video ACTION
```

For `list`, show the returned paths and stop. Otherwise stdout contains one absolute video path. Run:

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/extract-video-frames.py" "VIDEO_PATH"
```

The second command returns a JSON manifest with metadata, timestamps, and up to eight representative JPEG frames. Read all returned frames, compare them chronologically, and answer the user's request. If no request was supplied, provide:

- basic metadata
- a timestamped visual timeline
- important visible text or actions
- a concise summary

State that the analysis is visual when the manifest reports an audio track; do not claim to have transcribed or understood unheard audio. Do not modify or delete the received video. If receipt, probing, extraction, or reading fails, report the exact error instead of guessing.
