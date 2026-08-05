#!/usr/bin/env python3
"""Receive an image or video from Tailscale Taildrop and print its path."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

IMAGE_EXTENSIONS = {".bmp", ".gif", ".jpeg", ".jpg", ".png", ".webp"}
VIDEO_EXTENSIONS = {".m4v", ".mov", ".mp4", ".webm"}
RECEIVE_TIMEOUT_SECONDS = 20
WAIT_TIMEOUT_SECONDS = 5 * 60


@dataclass(frozen=True)
class MediaFile:
    path: Path
    modified_ns: int
    size: int


def upload_dir() -> Path:
    configured = os.environ.get("CLAUDE_TAILDROP_DIR") or os.environ.get("PI_TAILDROP_DIR")
    return Path(configured or Path.home() / "uploads" / "moshi").expanduser().resolve()


def list_media(directory: Path, extensions: set[str]) -> list[MediaFile]:
    media: list[MediaFile] = []
    for path in directory.iterdir():
        if path.is_symlink() or not path.is_file() or path.suffix.lower() not in extensions:
            continue
        metadata = path.stat()
        path.chmod(0o600)
        media.append(MediaFile(path.resolve(), metadata.st_mtime_ns, metadata.st_size))
    return sorted(media, key=lambda item: item.modified_ns, reverse=True)


def receive(directory: Path, wait: bool) -> None:
    tailscale = shutil.which("tailscale")
    if not tailscale:
        raise RuntimeError("tailscale is not installed or not on PATH")

    command = [tailscale, "file", "get", "--conflict=rename"]
    if wait:
        command.append("--wait")
    command.append(str(directory))

    timeout = WAIT_TIMEOUT_SECONDS if wait else RECEIVE_TIMEOUT_SECONDS
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"Taildrop receive timed out after {timeout} seconds") from error

    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise RuntimeError(f"Taildrop receive failed: {message}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("image", "video"))
    parser.add_argument("action", nargs="?", default="receive", choices=("receive", "wait", "latest", "list"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    directory = upload_dir()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    extensions = IMAGE_EXTENSIONS if args.kind == "image" else VIDEO_EXTENSIONS

    before = {item.path: (item.modified_ns, item.size) for item in list_media(directory, extensions)}
    if args.action in {"receive", "wait"}:
        receive(directory, wait=args.action == "wait")

    media = list_media(directory, extensions)
    if args.action == "list":
        for item in media[:5]:
            print(item.path)
        return 0

    if not media:
        raise RuntimeError(f"No supported {args.kind} files found in {directory}")

    received = [item for item in media if before.get(item.path) != (item.modified_ns, item.size)]
    selected = received[0] if received else media[0]
    print(selected.path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
