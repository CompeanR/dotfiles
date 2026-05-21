---
name: youtube-transcript
description: >
  Extract transcripts from YouTube videos using the global `yt-transcript` CLI.
  Trigger: When the user wants the transcript of a YouTube video, asks to extract captions, summarize a video by URL, or batch-process YouTube links. Also when the user says "transcripcion de youtube", "transcribe este video", or pastes a youtube.com / youtu.be URL with intent to read or analyze its content.
license: Apache-2.0
metadata:
  author: gentleman-programming
  version: "1.0"
---

## When to Use

Use this skill when ANY of the following apply:

- User pastes a YouTube URL and asks to read, summarize, analyze, or quote it.
- User explicitly asks for a transcript / captions / subtitles of a video.
- User wants to batch-process multiple YouTube URLs into transcript files.
- User wants a structured (JSON/SRT) export of a video's captions.

Do NOT use this skill for non-YouTube videos. For other platforms, fall back to a generic fetch or `yt-dlp` directly.

## Tool

Global CLI: `yt-transcript` (installed via `uv tool install -e ~/Development/tools/yt-transcript`).

Source: `~/Development/tools/yt-transcript/src/yt_transcript/`.

```text
usage: yt-transcript [-h] [--batch FILE] [-o OUTPUT] [--out-dir OUT_DIR]
                     [--format {txt,json,srt,md}] [--timestamps]
                     [--langs LANGS] [--cookies COOKIES] [--proxy PROXY]
                     [--no-cache]
                     [url]
```

## Standard Workflow

1. **Identify URL(s)**. Accept full YouTube URL, `youtu.be/...`, `youtube.com/shorts/...`, or 11-char video ID.
2. **Choose format**:
   - `txt` (default): plain reading; add `--timestamps` if you need anchors.
   - `md`: when saving a readable note (includes title + metadata header).
   - `json`: when downstream code/agent needs structured segments.
   - `srt`: when producing subtitle files.
3. **Run the CLI** via Bash:
   ```bash
   yt-transcript "<URL>" --format md -o /tmp/<slug>.md
   ```
4. **Read the output** with the Read tool, then perform the user's actual task (summarize, quote, translate, search, etc.).

## Recipes

### Quick read / summary

```bash
yt-transcript "<URL>" --format txt -o /tmp/yt-transcript.txt
```

Then `Read` `/tmp/yt-transcript.txt` and produce the summary.

### Structured analysis (timestamps + chunks)

```bash
yt-transcript "<URL>" --format json -o /tmp/yt-transcript.json
```

Parse `segments` for time-aligned excerpts.

### Batch ingestion

```bash
yt-transcript --batch urls.txt --out-dir transcripts/ --format md
```

One file per video, named after the video title.

### Multi-language preference

```bash
yt-transcript "<URL>" --langs es,en,ja --format txt
```

First match wins. Manual subtitles are preferred over auto-generated.

### Restricted / age-gated videos

```bash
yt-transcript "<URL>" --cookies ~/cookies.txt
```

## Behavior & Guardrails

- The CLI caches raw VTT under `~/.cache/yt-transcript/<video_id>.<source>.<lang>.vtt`. Use `--no-cache` to force refetch.
- Exit codes: `0` ok, `1` invalid/generic, `2` no captions, `3` fetch error.
- If `2` (no captions): tell the user the video has no usable captions; do NOT silently invent content. Offer manual transcription only if they explicitly request it.
- Long videos can produce large transcripts. Prefer writing to a file with `-o` and reading sections, instead of dumping the full text into the conversation.
- Never paste the entire transcript back to the user unless they explicitly ask. Default to a concise summary or the specific excerpts they asked for.

## Reinstall / Update

When you change source under `~/Development/tools/yt-transcript`:

```bash
uv tool install --reinstall -e ~/Development/tools/yt-transcript
```
