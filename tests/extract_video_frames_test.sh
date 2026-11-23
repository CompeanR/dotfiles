#!/usr/bin/env bash
# Regression test for agents/scripts/extract-video-frames.py, on generated videos.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/agents/scripts/extract-video-frames.py"

for tool in ffmpeg ffprobe python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip - $tool not found"; exit 0; }
done

tmp=$(mktemp -d)
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT
export HOME="$tmp/home"   # frames land in $HOME/.cache, away from the real cache
mkdir -p "$HOME"

# 15s landscape video with hard cuts at 4s and 9s.
ffmpeg -v error -y \
  -f lavfi -i "color=red:s=1280x720:d=4:r=30" \
  -f lavfi -i "color=blue:s=1280x720:d=5:r=30" \
  -f lavfi -i "testsrc=s=1280x720:d=6:r=30" \
  -filter_complex "[0][1][2]concat=n=3:v=1[v]" -map "[v]" -pix_fmt yuv420p "$tmp/cuts.mp4"
# 3s portrait video smaller than the still size.
ffmpeg -v error -y -f lavfi -i "testsrc2=s=540x960:d=3:r=30" -pix_fmt yuv420p "$tmp/portrait.mp4"

# 12s video whose first 2s are blurred, like a phone being set down.
ffmpeg -v error -y -f lavfi -i "testsrc2=s=1280x720:d=12:r=30" \
  -vf "boxblur=20:enable='lt(t,2)'" -pix_fmt yuv420p "$tmp/shaky.mp4"

python3 "$script" "$tmp/cuts.mp4" > "$tmp/overview.json"
python3 "$script" "$tmp/shaky.mp4" --frames 12 --sheets 0 > "$tmp/shaky.json"
python3 "$script" "$tmp/cuts.mp4" --start 0:03.5 --end 4.5 --frames 6 --sheets 0 > "$tmp/zoom.json"
python3 "$script" "$tmp/cuts.mp4" --frames 0 --sheets 1 > "$tmp/sheets.json"
python3 "$script" "$tmp/portrait.mp4" > "$tmp/portrait.json"

python3 - "$tmp" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

tmp = Path(sys.argv[1])


def load(name):
    return json.loads((tmp / name).read_text())


def size(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return tuple(int(part) for part in out.split(","))


def check(condition, message):
    if not condition:
        print(f"not ok - {message}")
        sys.exit(1)
    print(f"ok - {message}")


overview = load("overview.json")
changes = [f["timestamp_seconds"] for f in overview["frames"] if f["picked_for"] == "change"]
check(len(overview["frames"]) == 10, "overview returns 10 stills by default")
check(any(4.0 <= t <= 4.5 for t in changes) and any(9.0 <= t <= 9.5 for t in changes),
      f"stills land just after both cuts (got {changes})")
check(sum(len(s["tile_timestamps_seconds"]) for s in overview["sheets"]) == 30, "two sheets hold 30 tiles")
check(all(Path(item["path"]).is_file() for item in overview["frames"] + overview["sheets"]), "every image exists")
check(max(size(overview["sheets"][0]["path"])) <= 1568, "sheet fits in 1568px")
check(overview["timestamps_burned_in"] is True, "timestamps are burned in")

zoom = load("zoom.json")
times = [f["timestamp_seconds"] for f in zoom["frames"]]
check(zoom["window_seconds"] == [3.5, 4.5] and all(3.5 <= t <= 4.5 for t in times),
      "zoom keeps stills inside the window")
check(zoom["sheets"] == [], "--sheets 0 returns no sheets")

sheets = load("sheets.json")
check(sheets["frames"] == [] and len(sheets["sheets"]) == 1, "--frames 0 returns sheets only")

shaky = load("shaky.json")
ranges = shaky["blurred_ranges_seconds"]
check(shaky["blur_skipping"] == "on" and len(ranges) == 1 and ranges[0][0] <= 0.25 and 1.5 <= ranges[0][1] <= 2.0,
      f"the blurred opening is detected (got {ranges})")
early = [f for f in shaky["frames"] if f["timestamp_seconds"] < 2.0]
check(any(f["timestamp_seconds"] == 2.0 for f in shaky["frames"]),
      "a still due in the blurred opening moves to the first sharp frame")
check(len(early) == 1 and early[0].get("blurred") is True,
      "a still with no sharp frame in reach stays and is marked blurred")
check(not any(f.get("blurred") for f in shaky["frames"] if f["timestamp_seconds"] >= 2.0),
      "no sharp still is marked blurred")
check(overview["blurred_ranges_seconds"] == [], "flat colour frames, which have no blur reading, are not treated as blurred")

portrait = load("portrait.json")
check(size(portrait["frames"][0]["path"]) == (540, 960), "small portrait video is not upscaled")
check(portrait["sheets"][0]["grid"] == "5x3", "portrait tiles use a wide grid")
PY

if python3 "$script" "$tmp/cuts.mp4" --start 20 2>"$tmp/err"; then
  echo "not ok - a window past the end must fail"; exit 1
fi
grep -q "Empty window" "$tmp/err" && echo "ok - a window past the end fails with a clear error"

printf '\nok - extract-video-frames regression\n'
