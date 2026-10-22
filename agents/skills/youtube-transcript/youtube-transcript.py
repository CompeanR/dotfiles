#!/usr/bin/env python3
"""Print the path of a plain-text transcript for a YouTube video.

Captions first (several YouTube clients, since one is often rate-limited),
then the audio track transcribed locally with mlx-whisper.
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import subprocess
import sys
from pathlib import Path

CACHE = Path.home() / ".cache" / "youtube-transcripts"
CLIENTS = ["default", "tv", "web_safari", "mweb", "android", "ios"]
MODEL = "mlx-community/whisper-large-v3-turbo"


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True)


def video_id(url: str) -> str:
    out = run(["yt-dlp", "--skip-download", "--print", "%(id)s", url])
    if out.returncode != 0 or not out.stdout.strip():
        sys.exit(f"yt-dlp could not read {url}: {out.stderr.strip()[-300:]}")
    return out.stdout.strip().splitlines()[0]


def vtt_text(path: Path) -> str:
    lines: list[str] = []
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line == "WEBVTT" or "-->" in line or line.startswith(("Kind:", "Language:", "NOTE")):
            continue
        line = html.unescape(re.sub(r"<[^>]+>", "", line)).strip()
        if line and (not lines or line != lines[-1]):
            lines.append(line)
    return "\n".join(lines)


def from_captions(url: str, work: Path) -> str | None:
    for client in CLIENTS:
        args = ["yt-dlp", "--skip-download", "--write-subs", "--write-auto-subs",
                "--sub-langs", "en,en-orig,en-US", "--sub-format", "vtt",
                "-o", str(work / "captions.%(ext)s"), url]
        if client != "default":
            args[1:1] = ["--extractor-args", f"youtube:player_client={client}"]
        run(args)
        found = sorted(work.glob("captions*.vtt"))
        if found:
            text = vtt_text(found[0])
            if len(text.split()) > 50:
                return text
    return None


def from_audio(url: str, work: Path) -> str:
    for tool in ("ffmpeg", "uvx"):
        if not shutil.which(tool):
            sys.exit(f"captions unavailable and {tool} is missing (brew install {'ffmpeg' if tool == 'ffmpeg' else 'uv'})")
    audio = work / "audio.m4a"
    got = run(["yt-dlp", "-f", "bestaudio[ext=m4a]/bestaudio", "-o", str(audio), url])
    if got.returncode != 0 or not audio.exists():
        sys.exit(f"could not download audio: {got.stderr.strip()[-300:]}")
    whisper = run(["uvx", "--from", "mlx-whisper", "mlx_whisper", str(audio), "--model", MODEL,
                   "--output-format", "txt", "--output-dir", str(work), "--verbose", "False"])
    text_file = work / "audio.txt"
    if whisper.returncode != 0 or not text_file.exists():
        sys.exit(f"whisper failed: {whisper.stderr.strip()[-300:]}")
    return text_file.read_text()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("--audio", action="store_true", help="skip captions, transcribe the audio")
    args = parser.parse_args()

    if not shutil.which("yt-dlp"):
        sys.exit("yt-dlp is missing (brew install yt-dlp)")

    ident = video_id(args.url)
    out = CACHE / f"{ident}.txt"
    if out.exists():
        print(out)
        return

    work = CACHE / ident
    work.mkdir(parents=True, exist_ok=True)
    text = None if args.audio else from_captions(args.url, work)
    source = "captions"
    if text is None:
        text, source = from_audio(args.url, work), "whisper"

    out.write_text(text)
    shutil.rmtree(work, ignore_errors=True)
    print(out)
    print(f"source: {source}", file=sys.stderr)


if __name__ == "__main__":
    main()
