#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import zipfile
from pathlib import Path


IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract a zipped Figma flow pack and generate simple manifests.",
    )
    parser.add_argument("--zip", dest="zip_path", required=True, help="Path to the zip archive")
    parser.add_argument("--output", required=True, help="Directory where files will be extracted")
    return parser.parse_args()


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


def write_manifests(output_dir: Path, manifest: dict[str, list[str]]) -> None:
    manifest_json = output_dir / "manifest.json"
    manifest_txt = output_dir / "manifest.txt"

    manifest_json.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    lines: list[str] = []
    total = 0
    for group, files in manifest.items():
        lines.append(f"[{group}]")
        for file_name in files:
            lines.append(f"- {file_name}")
            total += 1
        lines.append("")
    lines.append(f"Total images: {total}")
    manifest_txt.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    zip_path = Path(args.zip_path).expanduser().resolve()
    output_dir = Path(args.output).expanduser().resolve()

    if not zip_path.exists():
        raise SystemExit(f"Zip not found: {zip_path}")

    output_dir.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(output_dir, members=safe_members(archive))

    manifest = build_manifest(output_dir)
    write_manifests(output_dir, manifest)

    print(f"Extracted to: {output_dir}")
    print(f"Flows indexed: {len(manifest)}")
    print(f"Manifest: {output_dir / 'manifest.txt'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
