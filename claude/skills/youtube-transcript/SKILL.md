---
name: youtube-transcript
description: Get the transcript of a YouTube video to read what it actually says. Use when the user shares a YouTube link or asks about a talk, video or approach from one.
allowed-tools:
  - Bash(python3 "${CLAUDE_SKILL_DIR}/../../scripts/youtube-transcript.py" *)
  - Read
---

# YouTube transcript

Read the source before answering about it: a title or a search snippet is not the talk.

## Run

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/youtube-transcript.py" "URL"
```

stdout is the path of a plain-text transcript, cached under `~/.cache/youtube-transcripts/<video id>.txt`; stderr names the source (`captions` or `whisper`).

- Captions come first, trying several YouTube clients because one is often rate-limited (HTTP 429).
- Without captions it downloads the audio and transcribes it locally with mlx-whisper (Apple silicon, via `uvx`). A one-hour talk takes a few minutes: run it with `run_in_background` and keep working.
- `--audio` skips captions (use it when captions are auto-generated garbage).

## Read

Read the whole transcript before answering; it is done when every part that bears on the user's question has been read. Quote the speaker for each claim you attribute to them, and say plainly when the talk does not cover what was asked.
