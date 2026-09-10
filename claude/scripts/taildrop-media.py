#!/usr/bin/env python3
"""Receive an image or video from Tailscale Taildrop and print its path."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

IMAGE_EXTENSIONS = {".bmp", ".gif", ".heic", ".heif", ".jpeg", ".jpg", ".png", ".webp"}
VIDEO_EXTENSIONS = {".m4v", ".mov", ".mp4", ".webm"}
CONVERTIBLE_EXTENSIONS = {".heic", ".heif"}
RECEIVE_TIMEOUT_SECONDS = {"image": 60, "video": 180}
WAIT_TIMEOUT_SECONDS = 5 * 60
STATUS_TIMEOUT_SECONDS = 10


@dataclass(frozen=True)
class MediaFile:
    path: Path
    modified_ns: int
    size: int


def upload_dir() -> Path:
    configured = os.environ.get("CLAUDE_TAILDROP_DIR") or os.environ.get("PI_TAILDROP_DIR")
    return Path(configured or Path.home() / "uploads" / "moshi").expanduser().resolve()


def fallback_dirs() -> list[Path]:
    """Where Taildrop lands when it never reaches the CLI inbox.

    The macOS Tailscale app saves incoming files straight to its own folder as they
    arrive, so `tailscale file get` drains an inbox that is already empty and the file
    is sitting in ~/Downloads instead.
    """
    configured = os.environ.get("CLAUDE_TAILDROP_FALLBACK_DIRS")
    raw = configured.split(os.pathsep) if configured else [str(Path.home() / "Downloads")]
    primary = upload_dir()
    found: list[Path] = []
    for item in raw:
        if not item.strip():
            continue
        try:
            path = Path(item).expanduser().resolve()
        except OSError:
            continue
        if path != primary and path.is_dir() and path not in found:
            found.append(path)
    return found


def fallback_window_seconds() -> int:
    try:
        return max(0, int(os.environ.get("CLAUDE_TAILDROP_WINDOW", "1800")))
    except ValueError:
        return 1800


def recent_media(directory: Path, extensions: set[str], window_seconds: int) -> list[MediaFile]:
    """Media modified inside the window. Never chmods: these are the user's own files."""
    cutoff_ns = int((time.time() - window_seconds) * 1_000_000_000)
    media: list[MediaFile] = []
    try:
        entries = list(directory.iterdir())
    except OSError:
        return []
    for path in entries:
        if path.is_symlink() or not path.is_file() or path.suffix.lower() not in extensions:
            continue
        try:
            metadata = path.stat()
        except OSError:
            continue
        if metadata.st_mtime_ns < cutoff_ns:
            continue
        media.append(MediaFile(path.resolve(), metadata.st_mtime_ns, metadata.st_size))
    return sorted(media, key=lambda item: item.modified_ns, reverse=True)


def fallback_candidates(extensions: set[str]) -> list[MediaFile]:
    window = fallback_window_seconds()
    candidates: list[MediaFile] = []
    for directory in fallback_dirs():
        candidates.extend(recent_media(directory, extensions, window))
    return sorted(candidates, key=lambda item: item.modified_ns, reverse=True)


def list_media(directory: Path, extensions: set[str]) -> list[MediaFile]:
    media: list[MediaFile] = []
    for path in directory.iterdir():
        if path.is_symlink() or not path.is_file() or path.suffix.lower() not in extensions:
            continue
        metadata = path.stat()
        path.chmod(0o600)
        media.append(MediaFile(path.resolve(), metadata.st_mtime_ns, metadata.st_size))
    return sorted(media, key=lambda item: item.modified_ns, reverse=True)


def snapshot_all(directory: Path) -> set[tuple[Path, int, int]]:
    """Every regular file, regardless of extension, so we can tell what Taildrop wrote."""
    entries: set[tuple[Path, int, int]] = set()
    for path in directory.iterdir():
        if path.is_symlink() or not path.is_file():
            continue
        metadata = path.stat()
        entries.add((path.resolve(), metadata.st_mtime_ns, metadata.st_size))
    return entries


def tailnet_identity(tailscale: str) -> tuple[str, list[str]]:
    """Return (this node's name, other node names). Never raises: diagnostics only."""
    try:
        result = subprocess.run(
            [tailscale, "status", "--json"],
            capture_output=True,
            text=True,
            timeout=STATUS_TIMEOUT_SECONDS,
            check=False,
        )
        if result.returncode != 0:
            return ("this machine", [])
        status = json.loads(result.stdout)

        def short_name(node: object) -> str:
            # DNSName is the name Taildrop shows in the share sheet; HostName is the
            # OS name, which can be a pretty string ("Javier's Mac mini") or "localhost".
            if not isinstance(node, dict):
                return ""
            name = node.get("DNSName") or node.get("HostName") or ""
            return name.split(".")[0] if isinstance(name, str) else ""

        this_node = short_name(status.get("Self") if isinstance(status, dict) else None) or "this machine"
        peer_map = status.get("Peer") if isinstance(status, dict) else None
        peers = sorted(
            filter(None, (short_name(peer) for peer in peer_map.values()))
        ) if isinstance(peer_map, dict) else []
    except (subprocess.SubprocessError, OSError, ValueError, AttributeError, TypeError):
        return ("this machine", [])

    return (this_node, peers)


def receive(directory: Path, wait: bool, kind: str) -> None:
    tailscale = shutil.which("tailscale")
    if not tailscale:
        raise RuntimeError("tailscale is not installed or not on PATH")

    command = [tailscale, "file", "get", "--conflict=rename"]
    if wait:
        command.append("--wait")
    command.append(str(directory))

    timeout = WAIT_TIMEOUT_SECONDS if wait else RECEIVE_TIMEOUT_SECONDS[kind]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"Taildrop receive timed out after {timeout} seconds") from error

    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise RuntimeError(f"Taildrop receive failed: {message}")


def convert_if_needed(path: Path) -> Path:
    """HEIC/HEIF are not universally readable; hand back a JPEG sibling when we can make one."""
    if path.suffix.lower() not in CONVERTIBLE_EXTENSIONS:
        return path
    sips = shutil.which("sips")
    if not sips:
        return path
    target = path.with_suffix(".jpg")
    try:
        if target.exists() and target.stat().st_mtime_ns >= path.stat().st_mtime_ns:
            return target
        result = subprocess.run(
            [sips, "-s", "format", "jpeg", str(path), "--out", str(target)],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if result.returncode != 0 or not target.exists():
            return path
        target.chmod(0o600)
    except (subprocess.SubprocessError, OSError):
        return path
    return target


def describe_age(modified_ns: int) -> str:
    seconds = max(0, int(time.time() - modified_ns / 1_000_000_000))
    if seconds < 90:
        return f"{seconds}s old"
    if seconds < 5400:
        return f"{seconds // 60}m old"
    if seconds < 172800:
        return f"{seconds // 3600}h old"
    return f"{seconds // 86400}d old"


def nothing_new_error(kind: str, directory: Path, unsupported: list[Path], media: list[MediaFile]) -> str:
    tailscale = shutil.which("tailscale")
    this_node, peers = tailnet_identity(tailscale) if tailscale else ("this machine", [])

    lines = [f"No new {kind} arrived in {this_node}'s Taildrop inbox ({directory})."]
    if unsupported:
        names = ", ".join(sorted(path.name for path in unsupported[:5]))
        lines.append(f"Unsupported files are present and were skipped: {names}")
        lines.append(f"Supported {kind} types: {', '.join(sorted(IMAGE_EXTENSIONS if kind == 'image' else VIDEO_EXTENSIONS))}")
    if peers:
        lines.append(f"Share to '{this_node}' — not to another node. Other nodes here: {', '.join(peers)}.")
    else:
        lines.append(f"Share to '{this_node}'.")
    searched = fallback_dirs()
    if searched:
        window_minutes = max(1, fallback_window_seconds() // 60)
        names = ", ".join(str(path) for path in searched)
        lines.append(f"Also checked for arrivals in the last {window_minutes}m under: {names}")
    if media:
        newest = media[0]
        lines.append(f"An older {kind} is available ({newest.path.name}, {describe_age(newest.modified_ns)}); pass 'latest' to use it.")
    return "\n".join(lines)


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

    before_media = {item.path: (item.modified_ns, item.size) for item in list_media(directory, extensions)}
    before_all = snapshot_all(directory)

    if args.action in {"receive", "wait"}:
        receive(directory, wait=args.action == "wait", kind=args.kind)

    media = list_media(directory, extensions)

    if args.action == "list":
        seen: set[Path] = set()
        for item in [*media, *fallback_candidates(extensions)][:5]:
            if item.path in seen:
                continue
            seen.add(item.path)
            print(item.path)
        return 0

    received = [item for item in media if before_media.get(item.path) != (item.modified_ns, item.size)]

    if args.action in {"receive", "wait"} and not received:
        newest_in_inbox = media[0].modified_ns if media else 0
        for candidate in fallback_candidates(extensions):
            if candidate.modified_ns <= newest_in_inbox:
                break
            print(
                f"Taildrop inbox was empty; using {candidate.path.name} "
                f"({describe_age(candidate.modified_ns)}) from {candidate.path.parent}.",
                file=sys.stderr,
            )
            print(convert_if_needed(candidate.path))
            return 0
        after_all = snapshot_all(directory)
        new_paths = {entry[0] for entry in after_all - before_all}
        unsupported = sorted(path for path in new_paths if path.suffix.lower() not in extensions)
        raise RuntimeError(nothing_new_error(args.kind, directory, unsupported, media))

    if not media:
        raise RuntimeError(nothing_new_error(args.kind, directory, [], media))

    selected = received[0] if received else media[0]
    print(convert_if_needed(selected.path))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
