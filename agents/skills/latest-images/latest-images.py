#!/usr/bin/env python3
"""Return the latest N images received via Taildrop as absolute paths.

Solves the batch-retrieval scenarios the single-image `/image` skill doesn't:
  - grabbing the latest N images at once (e.g. a set of 6 screenshots)
  - keeping them in capture order (oldest-first) so they map to shot 1..N
  - filtering out unrelated `pi-window-*` remote-viewer screen grabs so a
    device photo batch (`IMG_*`) isn't polluted by them
"""
import argparse
import os
import subprocess
import sys

UPLOAD_DIRS = [os.path.expanduser("~/uploads/moshi")]


def drain_taildrop(target_dir):
    """Pull any pending files from the Tailscale inbox before listing."""
    os.makedirs(target_dir, exist_ok=True)
    try:
        subprocess.run(
            ["tailscale", "file", "get", "--conflict=rename", target_dir],
            capture_output=True, timeout=10,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".heic", ".heif", ".webp", ".gif", ".tiff"}


def is_image(path):
    return os.path.splitext(path)[1].lower() in IMAGE_EXTS


def classify(name):
    n = name.lower()
    if n.startswith("img_"):        # iPhone / device camera-roll captures
        return "iphone"
    if n.startswith("pi-window"):   # moshi remote-viewer window screen grabs
        return "window"
    return "other"


def main():
    ap = argparse.ArgumentParser(
        description="Return the latest N Taildrop-uploaded images as absolute paths (one per line)."
    )
    ap.add_argument("count", nargs="?", type=int, default=1,
                    help="how many of the latest images to return (default 1)")
    ap.add_argument("--type", choices=["user", "iphone", "window", "other", "all"], default="user",
                    help="source filter: user=all except pi-window-* (default), "
                         "iphone=IMG_* device captures, window=pi-window-* screen grabs, "
                         "other=neither, all=any image")
    ap.add_argument("--order", choices=["oldest", "newest"], default="oldest",
                    help="order of the returned batch: oldest-first (default, preserves "
                         "capture order so a set comes back as shot 1..N) or newest-first")
    ap.add_argument("--dir", action="append", default=None,
                    help="override upload dir(s); repeatable")
    args = ap.parse_args()

    if args.count < 1:
        ap.error("count must be >= 1")

    dirs = args.dir if args.dir else UPLOAD_DIRS
    for d in dirs:
        drain_taildrop(d)
    files = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            p = os.path.join(d, name)
            if not os.path.isfile(p) or not is_image(p):
                continue
            image_type = classify(name)
            if args.type == "user":
                if image_type == "window":
                    continue
            elif args.type != "all" and image_type != args.type:
                continue
            files.append(p)

    if not files:
        print(f"No images found (type={args.type}) in: {', '.join(dirs)}", file=sys.stderr)
        sys.exit(1)

    files.sort(key=lambda p: (os.path.getmtime(p), p), reverse=True)  # newest first, deterministic ties
    batch = files[:args.count]
    if args.order == "oldest":
        batch = list(reversed(batch))                            # capture order

    for p in batch:
        print(os.path.abspath(p))


if __name__ == "__main__":
    main()
