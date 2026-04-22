#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import zipfile
from datetime import datetime
from pathlib import Path


IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract the latest zip from ~/Downloads (or a given path) and emit a manifest.",
    )
    parser.add_argument(
        "--zip",
        dest="zip_path",
        default=None,
        help="Path to a specific zip archive. If omitted, picks the newest .zip in --downloads.",
    )
    parser.add_argument(
        "--downloads",
        default="~/Downloads",
        help="Directory to search for the latest zip (used when --zip is omitted). Default: ~/Downloads",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Directory where files will be extracted. Default: /tmp/zip-pack-{zip-stem}",
    )
    return parser.parse_args()


def find_latest_zip(downloads_dir: Path) -> Path:
    if not downloads_dir.exists():
        raise SystemExit(f"Downloads directory not found: {downloads_dir}")
    zips = [p for p in downloads_dir.glob("*.zip") if p.is_file()]
    if not zips:
        raise SystemExit(f"No .zip files found in {downloads_dir}")
    return max(zips, key=lambda p: p.stat().st_mtime)


def safe_members(archive: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
    members: list[zipfile.ZipInfo] = []
    for member in archive.infolist():
        target = Path(member.filename)
        if target.is_absolute() or ".." in target.parts:
            continue
        members.append(member)
    return members


def build_manifest(output_dir: Path) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {}
    for path in sorted(output_dir.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        relative = path.relative_to(output_dir)
        group = str(relative.parent) if str(relative.parent) != "." else "root"
        grouped.setdefault(group, []).append(str(relative))
    return grouped


def write_manifests(output_dir: Path, manifest: dict[str, list[str]], source_zip: Path) -> int:
    manifest_json = output_dir / "manifest.json"
    manifest_txt = output_dir / "manifest.txt"

    total = sum(len(files) for files in manifest.values())

    manifest_json.write_text(
        json.dumps(
            {
                "source_zip": str(source_zip),
                "extracted_at": datetime.now().isoformat(timespec="seconds"),
                "total_images": total,
                "groups": manifest,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    lines: list[str] = [f"Source: {source_zip}", ""]
    for group, files in manifest.items():
        lines.append(f"[{group}]")
        for file_name in files:
            lines.append(f"- {file_name}")
        lines.append("")
    lines.append(f"Total images: {total}")
    manifest_txt.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")
    return total


def main() -> int:
    args = parse_args()

    if args.zip_path:
        zip_path = Path(args.zip_path).expanduser().resolve()
        if not zip_path.exists():
            raise SystemExit(f"Zip not found: {zip_path}")
    else:
        downloads_dir = Path(args.downloads).expanduser().resolve()
        zip_path = find_latest_zip(downloads_dir)

    if args.output:
        output_dir = Path(args.output).expanduser().resolve()
    else:
        output_dir = Path(f"/tmp/zip-pack-{zip_path.stem}").resolve()

    output_dir.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(output_dir, members=safe_members(archive))

    manifest = build_manifest(output_dir)
    total = write_manifests(output_dir, manifest, zip_path)

    print(f"Source zip:   {zip_path}")
    print(f"Extracted to: {output_dir}")
    print(f"Groups:       {len(manifest)}")
    print(f"Images:       {total}")
    print(f"Manifest:     {output_dir / 'manifest.txt'}")
    print("")
    print("Absolute image paths (ready for Read tool):")
    for group, files in manifest.items():
        for file_name in files:
            print(f"  {output_dir / file_name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
