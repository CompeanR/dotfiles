---
name: video
description: Receive the newest video through Tailscale Taildrop, extract stills and contact sheets with ffmpeg, and analyze its visual content. Use only when the user invokes /video.
argument-hint: "[wait|latest|list] [question]"
disable-model-invocation: true
allowed-tools:
  - Bash(python3 "${CLAUDE_SKILL_DIR}/../../scripts/taildrop-media.py" *)
  - Bash(python3 "${CLAUDE_SKILL_DIR}/../../scripts/extract-video-frames.py" *)
  - Read
---

# Taildrop video

Receive and visually analyze a video without asking the user for its local path.

## 1. Receive

Interpret `$ARGUMENTS` as follows:

- If the first word is `wait`, `latest`, or `list`, use that as the action.
- Otherwise use `receive`; treat all arguments as the user's analysis request.
- Any text after an action is also the analysis request.

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/taildrop-media.py" video ACTION
```

For `list`, show the returned paths and stop. Otherwise stdout contains one absolute video path.

## 2. Overview pass

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/extract-video-frames.py" "VIDEO_PATH"
```

If the request names a time range, add `--start` and `--end` (seconds or `m:ss`) on this first run.

The JSON manifest has two kinds of images. Read all of them, in time order:

- `frames`: full-size stills. `picked_for: change` marks a cut or screen change; `coverage` fills the gaps evenly. Use these for detail and small text.
- `sheets`: contact sheets of small tiles, read left to right, top to bottom. Use these for what happens between stills: motion, order of events, how long something lasts.

Every image has its timestamp burned into the top-left corner. Cite those timestamps.

Stills are moved off blurred frames. `blurred_ranges_seconds` lists the stretches that were blurred, usually the phone being handled; a still marked `blurred: true` had no sharp frame nearby. Do not read detail from a blurred frame.

## 3. Zoom pass

The manifest's `sample_gap_seconds` is how far apart the samples are. Anything shorter can fall between them. Before answering, check whether the request depends on something the overview does not show clearly: a fast movement, a brief state, text too small to read on a tile, the exact moment something starts. If so, rerun on a short window around it:

```bash
# Detail: full-size stills only
python3 "${CLAUDE_SKILL_DIR}/../../scripts/extract-video-frames.py" "VIDEO_PATH" --start 36 --end 38 --frames 16 --sheets 0

# Motion: dense tiles only
python3 "${CLAUDE_SKILL_DIR}/../../scripts/extract-video-frames.py" "VIDEO_PATH" --start 36 --end 38 --frames 0 --sheets 2
```

Limits: `--frames` 0 to 40, `--sheets` 0 to 6. Zoom as many times as the question needs; stop when another pass would not change the answer.

## 4. Answer

Answer the user's request. If no request was supplied, provide:

- basic metadata
- a timestamped visual timeline
- important visible text or actions
- a concise summary

Rules:

- Say only what a frame shows. Motion between two samples is an inference: label it as one, or zoom to confirm it.
- When the answer rests on a gap you did not zoom into, say what the gap was.
- When `has_audio` is true, state that the analysis is visual only. Do not claim to have heard or transcribed audio.
- Do not modify or delete the received video.
- If receipt, probing, extraction, or reading fails, report the exact error instead of guessing.
