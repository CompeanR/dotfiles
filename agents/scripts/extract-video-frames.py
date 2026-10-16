#!/usr/bin/env python3
"""Extract evenly spaced video frames and print a JSON manifest."""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CACHE_ROOT = Path.home() / ".cache" / "claude-media"
MAX_FRAMES = 12
STALE_AFTER_SECONDS = 24 * 60 * 60


def executable(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"{name} is not installed or not on PATH")
    return path


def remove_stale_directories() -> None:
    if not CACHE_ROOT.is_dir():
        return
    cutoff = time.time() - STALE_AFTER_SECONDS
    for directory in CACHE_ROOT.glob("video-frames-*"):
        try:
            if directory.is_dir() and directory.stat().st_mtime < cutoff:
                shutil.rmtree(directory)
        except OSError:
            pass


def probe(video: Path) -> dict:
    command = [
        executable("ffprobe"),
        "-v",
        "error",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        str(video),
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("ffprobe timed out after 30 seconds") from error
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "ffprobe failed")
    return json.loads(result.stdout)


def duration_seconds(metadata: dict) -> float:
    candidates = [metadata.get("format", {}).get("duration")]
    candidates.extend(stream.get("duration") for stream in metadata.get("streams", []))
    for candidate in candidates:
        try:
            duration = float(candidate)
            if math.isfinite(duration) and duration > 0:
                return duration
        except (TypeError, ValueError):
            continue
    raise RuntimeError("Video duration is unavailable")


def extract_frame(ffmpeg: str, video: Path, timestamp: float, destination: Path) -> None:
    command = [
        ffmpeg,
        "-v",
        "error",
        "-ss",
        f"{timestamp:.3f}",
        "-i",
        str(video),
        "-frames:v",
        "1",
        "-vf",
        "scale=1280:-2:force_original_aspect_ratio=decrease",
        "-q:v",
        "4",
        "-y",
        str(destination),
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"ffmpeg timed out at {timestamp:.1f}s") from error
    if result.returncode != 0 or not destination.is_file():
        raise RuntimeError(result.stderr.strip() or f"ffmpeg failed at {timestamp:.1f}s")
    destination.chmod(0o600)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--frames", type=int, default=8)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    video = args.video.expanduser().resolve()
    if not video.is_file():
        raise RuntimeError(f"Video does not exist: {video}")

    metadata = probe(video)
    video_streams = [stream for stream in metadata.get("streams", []) if stream.get("codec_type") == "video"]
    if not video_streams:
        raise RuntimeError("The file has no video stream")

    duration = duration_seconds(metadata)
    requested = max(1, min(args.frames, MAX_FRAMES))
    frame_count = min(requested, max(1, math.ceil(duration * 2)))

    CACHE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    CACHE_ROOT.chmod(0o700)
    remove_stale_directories()
    output_dir = Path(tempfile.mkdtemp(prefix="video-frames-", dir=CACHE_ROOT))
    output_dir.chmod(0o700)

    ffmpeg = executable("ffmpeg")
    frames = []
    try:
        for index in range(frame_count):
            timestamp = duration * (index + 0.5) / frame_count
            destination = output_dir / f"frame-{index + 1:02d}-{timestamp:.2f}s.jpg"
            extract_frame(ffmpeg, video, timestamp, destination)
            frames.append({"path": str(destination), "timestamp_seconds": round(timestamp, 3)})
    except Exception:
        shutil.rmtree(output_dir, ignore_errors=True)
        raise

    stream = video_streams[0]
    manifest = {
        "video": str(video),
        "duration_seconds": round(duration, 3),
        "width": stream.get("width"),
        "height": stream.get("height"),
        "codec": stream.get("codec_name"),
        "has_audio": any(item.get("codec_type") == "audio" for item in metadata.get("streams", [])),
        "frames": frames,
    }
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, json.JSONDecodeError, OSError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
