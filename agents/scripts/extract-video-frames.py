#!/usr/bin/env python3
"""Extract video frames for visual analysis and print a JSON manifest.

Two kinds of images come back:

- frames: full-size stills. Up to half go to the biggest visual changes
  (cuts, screen transitions), the rest keep even coverage of the window. Stills
  are moved off blurred frames, such as a phone being picked up.
- sheets: contact sheets of small, evenly spaced tiles, read left to right and
  top to bottom. They show what happens between the stills.

Every image has its timestamp burned into the top-left corner. Use --start and
--end to zoom into a short window and sample it densely.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

CACHE_ROOT = Path.home() / ".cache" / "claude-media"
STALE_AFTER_SECONDS = 24 * 60 * 60

DEFAULT_FRAMES = 10
MAX_FRAMES = 40
DEFAULT_SHEETS = 2
MAX_SHEETS = 6
FRAME_LONG_EDGE = 1280
TILE_LONG_EDGE = 512
SHEET_EDGE = 1568
TILE_GAP = 4

CHANGE_SCAN_TIMEOUT_SECONDS = 180
CHANGE_MIN_SCORE = 0.08
CHANGE_SETTLE_SECONDS = 0.2
CHANGE_SHARP_REACH_SECONDS = 1.0
BLUR_RATIO = 1.25  # a sample this many times blurrier than the window's median counts as blurred
BLUR_MIN_SAMPLES = 8
BLUR_MAX_SHARE = 1 / 3
WORKERS = 4

SCORE_LINE = re.compile(r"pts_time:([0-9.]+)")
Sample = tuple[float, float, "float | None"]  # timestamp, change score, blur
labels_enabled = True


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


def frame_rate(stream: dict) -> float:
    for key in ("avg_frame_rate", "r_frame_rate"):
        try:
            numerator, _, denominator = str(stream.get(key, "")).partition("/")
            rate = float(numerator) / float(denominator or 1)
            if math.isfinite(rate) and rate > 0:
                return rate
        except (ValueError, ZeroDivisionError):
            continue
    return 30.0


def display_size(stream: dict) -> tuple[int, int]:
    """Width and height as shown on screen: phones store portrait video rotated."""
    width, height = int(stream.get("width") or 0), int(stream.get("height") or 0)
    if width <= 0 or height <= 0:
        raise RuntimeError("Video dimensions are unavailable")
    rotation = 0.0
    for side_data in stream.get("side_data_list", []):
        if "rotation" in side_data:
            rotation = float(side_data["rotation"])
    if not rotation:
        try:
            rotation = float(stream.get("tags", {}).get("rotate", 0))
        except (TypeError, ValueError):
            rotation = 0.0
    if round(abs(rotation)) % 180 == 90:
        width, height = height, width
    return width, height


def fit(width: int, height: int, long_edge: int) -> tuple[int, int]:
    """Scale down to the long edge, never up, keeping even dimensions."""
    scale = min(1.0, long_edge / max(width, height))
    return max(2, round(width * scale / 2) * 2), max(2, round(height * scale / 2) * 2)


def parse_time(text: str) -> float:
    """Accept seconds (36.8) or clock time (0:36.8, 1:02:03)."""
    try:
        seconds = 0.0
        for part in text.strip().split(":"):
            seconds = seconds * 60 + float(part)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"not a time: {text!r} (use 36.8 or 0:36.8)") from error
    if not math.isfinite(seconds) or seconds < 0:
        raise argparse.ArgumentTypeError(f"not a time: {text!r}")
    return seconds


def label_for(timestamp: float) -> str:
    """Timestamp text without colons, so it needs no escaping inside an ffmpeg filter."""
    if timestamp < 60:
        return f"{timestamp:.2f}s"
    minutes, seconds = divmod(timestamp, 60)
    return f"{int(minutes)}m{seconds:05.2f}s"


def run_ffmpeg(arguments: list[str], timeout: int) -> subprocess.CompletedProcess:
    return subprocess.run(
        [executable("ffmpeg"), "-v", "error", *arguments],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def extract_frame(video: Path, timestamp: float, destination: Path, size: tuple[int, int]) -> None:
    global labels_enabled
    width, height = size
    scale = f"scale={width}:{height}"
    font_size = max(13, round(min(width, height) / 24))
    label = (
        f"drawtext=text='{label_for(timestamp)}':x=6:y=6:fontsize={font_size}:fontcolor=white"
        ":box=1:boxcolor=black@0.65:boxborderw=5"
    )
    for video_filter in ([f"{scale},{label}", scale] if labels_enabled else [scale]):
        arguments = ["-ss", f"{timestamp:.3f}", "-i", str(video), "-frames:v", "1", "-vf", video_filter]
        arguments += ["-q:v", "3", "-y", str(destination)]
        try:
            result = run_ffmpeg(arguments, timeout=60)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"ffmpeg timed out at {timestamp:.1f}s") from error
        if result.returncode == 0 and destination.is_file():
            destination.chmod(0o600)
            return
        if video_filter != scale and "drawtext" in result.stderr.lower():
            labels_enabled = False  # no usable font: keep going without burned-in timestamps
            continue
        raise RuntimeError(result.stderr.strip() or f"ffmpeg failed at {timestamp:.1f}s")
    raise RuntimeError(f"ffmpeg failed at {timestamp:.1f}s")


def extract_many(video: Path, jobs: list[tuple[float, Path]], size: tuple[int, int]) -> None:
    if not jobs:
        return
    extract_frame(video, jobs[0][0], jobs[0][1], size)  # settles labels_enabled before fanning out
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        list(pool.map(lambda job: extract_frame(video, job[0], job[1], size), jobs[1:]))


def scan(video: Path, start: float, length: float) -> list[Sample]:
    """Sample the window: how much each frame differs from the one before, and how blurred it is."""
    rate = 4 if length <= 300 else 2 if length <= 1200 else 1
    for blur_filter in ("blurdetect,", ""):
        arguments = ["-ss", f"{start:.3f}", "-t", f"{length:.3f}", "-i", str(video), "-an", "-vf"]
        arguments += [f"fps={rate},scale=480:-2,{blur_filter}select='gte(scene,0)',metadata=print:file=-"]
        arguments += ["-f", "null", "-"]
        result = run_ffmpeg(arguments, timeout=CHANGE_SCAN_TIMEOUT_SECONDS)
        if result.returncode == 0:
            break
        if not (blur_filter and "blurdetect" in result.stderr.lower()):
            raise RuntimeError(result.stderr.strip() or "scan failed")

    samples: list[Sample] = []
    timestamp, score, blur = None, 0.0, None
    for line in [*result.stdout.splitlines(), "pts_time:0"]:  # the extra line flushes the last sample
        match = SCORE_LINE.search(line)
        if match:
            if timestamp is not None:
                samples.append((start + timestamp, score, blur))
            timestamp, score, blur = float(match.group(1)), 0.0, None
        elif line.startswith("lavfi.scene_score="):
            score = float(line.split("=", 1)[1])
        elif line.startswith("lavfi.blur="):
            value = float(line.split("=", 1)[1])
            blur = value if math.isfinite(value) else None  # a frame with no edges has no reading
    return samples


def find_blurred(samples: list[Sample]) -> tuple[set[float], str]:
    """Samples clearly blurrier than the rest of the window, such as a phone being picked up."""
    blurs = [blur for _, _, blur in samples if blur is not None]
    if not blurs:
        return set(), "off: this ffmpeg has no blurdetect filter"
    baseline = statistics.median(blurs)
    blurred = {timestamp for timestamp, _, blur in samples if blur is not None and blur > baseline * BLUR_RATIO}
    # Blur is judged against the window itself, so it only means something when most of it is sharp.
    if len(blurs) < BLUR_MIN_SAMPLES or baseline <= 0 or len(blurred) > len(samples) * BLUR_MAX_SHARE:
        return set(), "off: no clear sharp baseline in this window"
    return blurred, "on"


def blurred_ranges(samples: list[Sample], blurred: set[float]) -> list[list[float]]:
    ranges: list[list[float]] = []
    previous_blurred = False
    for timestamp, _, _ in samples:
        if timestamp in blurred:
            if previous_blurred:
                ranges[-1][1] = round(timestamp, 3)
            else:
                ranges.append([round(timestamp, 3), round(timestamp, 3)])
        previous_blurred = timestamp in blurred
    return ranges


def even_timestamps(start: float, length: float, count: int) -> list[float]:
    return [start + length * (index + 0.5) / count for index in range(count)]


def pick_frame_timestamps(
    samples: list[Sample], blurred: set[float], start: float, length: float, count: int
) -> list[tuple[float, str, bool]]:
    """Even coverage, with slots moved onto big visual changes and off blurred frames."""
    slots = even_timestamps(start, length, count)
    reasons = ["coverage"] * count
    if not samples:
        return [(slot, reason, False) for slot, reason in zip(slots, reasons)]

    times = [timestamp for timestamp, _, _ in samples]
    sharp = [timestamp for timestamp in times if timestamp not in blurred]

    def is_blurred(timestamp: float) -> bool:
        return min(times, key=lambda sample: abs(sample - timestamp)) in blurred

    def sharp_near(timestamp: float, reach: float, forward: bool = False) -> float | None:
        near = [s for s in sharp if abs(s - timestamp) <= reach and (s >= timestamp or not forward)]
        return min(near, key=lambda sample: abs(sample - timestamp), default=None)

    end = start + length
    threshold = max(CHANGE_MIN_SCORE, 4 * statistics.median(score for _, score, _ in samples))
    min_gap = length / (count * 2)
    changes: list[float] = []
    for timestamp, score, _ in sorted(samples, key=lambda sample: sample[1], reverse=True):
        if score < threshold or len(changes) >= count // 2:
            break
        # The scored frame is the first one showing new content; step past any transition.
        target = min(timestamp + CHANGE_SETTLE_SECONDS, end - 0.01)
        if is_blurred(target):
            target = sharp_near(timestamp, CHANGE_SHARP_REACH_SECONDS, forward=True)
            if target is None:
                continue  # the change is camera shake, not new content worth a still
        if all(abs(target - other) >= min_gap for other in changes):
            changes.append(target)

    for change in changes:
        free = [index for index in range(count) if reasons[index] == "coverage"]
        nearest = min(free, key=lambda index: abs(slots[index] - change))
        slots[nearest] = change
        reasons[nearest] = "change"

    for index in range(count):
        if reasons[index] == "coverage" and is_blurred(slots[index]):
            replacement = sharp_near(slots[index], length / count / 2)
            if replacement is not None and replacement not in slots:
                slots[index] = replacement
    return sorted((slot, reason, is_blurred(slot)) for slot, reason in zip(slots, reasons))


def sheet_layout(tile: tuple[int, int]) -> tuple[int, int]:
    columns = max(1, (SHEET_EDGE - TILE_GAP) // (tile[0] + TILE_GAP))
    rows = max(1, (SHEET_EDGE - TILE_GAP) // (tile[1] + TILE_GAP))
    return columns, rows


def build_sheets(
    video: Path, output_dir: Path, timestamps: list[float], tile: tuple[int, int], per_sheet: int, columns: int
) -> list[dict]:
    tiles_dir = output_dir / "tiles"
    tiles_dir.mkdir(mode=0o700)
    groups = [timestamps[index : index + per_sheet] for index in range(0, len(timestamps), per_sheet)]
    jobs = [
        (timestamp, tiles_dir / f"s{sheet:02d}-{position:03d}.jpg")
        for sheet, group in enumerate(groups, start=1)
        for position, timestamp in enumerate(group, start=1)
    ]
    extract_many(video, jobs, tile)

    sheets = []
    for sheet, group in enumerate(groups, start=1):
        rows = math.ceil(len(group) / columns)
        destination = output_dir / f"sheet-{sheet:02d}-{group[0]:.2f}s-{group[-1]:.2f}s.jpg"
        arguments = ["-framerate", "1", "-start_number", "1", "-i", str(tiles_dir / f"s{sheet:02d}-%03d.jpg")]
        arguments += ["-vf", f"tile={columns}x{rows}:padding={TILE_GAP}:margin={TILE_GAP}:color=black"]
        arguments += ["-frames:v", "1", "-q:v", "3", "-y", str(destination)]
        result = run_ffmpeg(arguments, timeout=60)
        if result.returncode != 0 or not destination.is_file():
            raise RuntimeError(result.stderr.strip() or f"ffmpeg failed building sheet {sheet}")
        destination.chmod(0o600)
        sheets.append(
            {
                "path": str(destination),
                "grid": f"{columns}x{rows}",
                "reading_order": "left to right, top to bottom",
                "tile_timestamps_seconds": [round(timestamp, 3) for timestamp in group],
            }
        )
    shutil.rmtree(tiles_dir, ignore_errors=True)
    return sheets


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("video", type=Path)
    parser.add_argument("--frames", type=int, default=DEFAULT_FRAMES, help=f"full-size stills, 0 to {MAX_FRAMES}")
    parser.add_argument("--sheets", type=int, default=DEFAULT_SHEETS, help=f"contact sheets, 0 to {MAX_SHEETS}")
    parser.add_argument("--start", type=parse_time, default=0.0, help="window start: 36.8 or 0:36.8")
    parser.add_argument("--end", type=parse_time, default=None, help="window end: 36.8 or 0:36.8")
    parser.add_argument("--even", action="store_true", help="space stills evenly; skip change detection")
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
    stream = video_streams[0]

    duration = duration_seconds(metadata)
    rate = frame_rate(stream)
    start = args.start
    end = duration if args.end is None else min(args.end, duration)
    if start >= end:
        raise RuntimeError(f"Empty window: start {start:.2f}s, end {end:.2f}s, video is {duration:.2f}s long")
    length = end - start
    available = max(1, math.floor(length * rate))  # distinct source frames in the window

    frame_count = min(max(0, min(args.frames, MAX_FRAMES)), available)
    sheet_count = max(0, min(args.sheets, MAX_SHEETS))
    if frame_count == 0 and sheet_count == 0:
        raise RuntimeError("Nothing to extract: --frames and --sheets are both 0")

    width, height = display_size(stream)
    frame_size = fit(width, height, FRAME_LONG_EDGE)
    tile_size = fit(width, height, TILE_LONG_EDGE)
    columns, rows = sheet_layout(tile_size)
    tile_count = min(sheet_count * columns * rows, available)
    if tile_count <= frame_count:
        tile_count = 0  # the stills already show every moment the sheets would

    CACHE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    CACHE_ROOT.chmod(0o700)
    remove_stale_directories()
    output_dir = Path(tempfile.mkdtemp(prefix="video-frames-", dir=CACHE_ROOT))
    output_dir.chmod(0o700)

    change_detection = blur_skipping = "off"
    samples: list[Sample] = []
    blurred: set[float] = set()
    if frame_count >= 2 and not args.even:
        try:
            samples = scan(video, start, length)
            change_detection = "on"
            blurred, blur_skipping = find_blurred(samples)
        except subprocess.TimeoutExpired:
            change_detection = f"timed out after {CHANGE_SCAN_TIMEOUT_SECONDS}s; stills are evenly spaced"
        except RuntimeError as error:
            change_detection = f"failed ({error}); stills are evenly spaced"

    last_frame = max(start, duration - 2 / rate)  # seeking onto the final frame can return nothing
    try:
        picked = pick_frame_timestamps(samples, blurred, start, length, frame_count) if frame_count else []
        frames = []
        jobs = []
        for index, (timestamp, reason, is_blurred) in enumerate(picked, start=1):
            timestamp = min(timestamp, last_frame)
            destination = output_dir / f"frame-{index:02d}-{timestamp:.2f}s.jpg"
            jobs.append((timestamp, destination))
            frame = {"path": str(destination), "timestamp_seconds": round(timestamp, 3), "picked_for": reason}
            if is_blurred:
                frame["blurred"] = True  # no sharp frame was close enough to swap in
            frames.append(frame)
        extract_many(video, jobs, frame_size)

        tile_timestamps = [min(timestamp, last_frame) for timestamp in even_timestamps(start, length, tile_count)]
        sheets = build_sheets(video, output_dir, tile_timestamps, tile_size, columns * rows, columns) if tile_count else []
    except Exception:
        shutil.rmtree(output_dir, ignore_errors=True)
        raise

    densest = max(frame_count, tile_count)
    manifest = {
        "video": str(video),
        "duration_seconds": round(duration, 3),
        "window_seconds": [round(start, 3), round(end, 3)],
        "width": width,
        "height": height,
        "frame_rate": round(rate, 3),
        "codec": stream.get("codec_name"),
        "has_audio": any(item.get("codec_type") == "audio" for item in metadata.get("streams", [])),
        "timestamps_burned_in": labels_enabled,
        "change_detection": change_detection,
        "blur_skipping": blur_skipping,
        "blurred_ranges_seconds": blurred_ranges(samples, blurred),
        "sample_gap_seconds": round(length / densest, 3),
        "blind_spot": (
            f"Samples are about {length / densest:.2f}s apart. Anything shorter than that can fall between "
            "them unseen; rerun with --start/--end around the moment to look closer."
        ),
        "frames": frames,
        "sheets": sheets,
    }
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, json.JSONDecodeError, OSError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
