---
name: downloads-zip-pack
description: >
    Extract the latest zip file from ~/Downloads (or a given path), build an image manifest,
    and make the contained screenshots available as conversation context.
    Trigger: When the user says they downloaded a zip of screenshots/references and wants
    the agent to unzip and inspect them. Common phrases: "I downloaded a zip",
    "the last file in my Downloads is a zip", "extract the latest zip",
    "descargue un zip", "agrega los screenshots".
license: Apache-2.0
metadata:
    author: gentleman-programming
    version: "1.0"
---

## When to Use

Use this skill when:

- The user says they downloaded a zip of screenshots/images and wants you to look at them.
- The user references a "latest zip" or "most recent download" without providing a path.
- You need to ingest a multi-image reference pack into the conversation context.
- The user describes this as a "common workflow" (batches of screenshots in zips).

Prefer this skill over `figma-flow-pack` when the zip is NOT a Figma export or when the
user just wants "the latest zip I downloaded." Use `figma-flow-pack` when the zip is
specifically a Figma flow export and flow-level analysis matters more than simple ingestion.

---

## Critical Patterns

### Pattern 1: Never ask the user for the zip path when they said "latest in Downloads"

Run the script without `--zip`. It finds the newest `.zip` in `~/Downloads` by mtime.

```bash
python3 /home/compean/.config/opencode/skills/downloads-zip-pack/assets/extract_latest.py
```

### Pattern 2: After extraction, READ the images — do not just list filenames

The script prints absolute paths of every extracted image. Pass those paths DIRECTLY to
the Read tool in parallel tool calls — one Read per image. The user wants visual analysis,
not a file listing.

### Pattern 3: Keep extraction output in /tmp, not in the repo

Default output is `/tmp/zip-pack-{zip-stem}`. Do NOT extract into the user's working
directory unless they explicitly ask. Reference assets belong outside version control.

### Pattern 4: Trust the zip, but validate structure

The script rejects path-traversal entries (`..`, absolute paths). If the zip contains
non-image files (e.g. `.DS_Store`, `.heic`, PDFs), the manifest filters to only images
listed in `IMAGE_EXTENSIONS`. If you need non-image files, list the output directory
directly instead of relying on the manifest.

---

## Decision Tree

```
User said "I downloaded a zip" without a path?   → Run script with no --zip arg
User provided a specific zip path?               → Run script with --zip {path}
User wants a specific output location?           → Pass --output {dir}
Manifest shows many images?                      → Read the first 4-8 in parallel, offer to read more
Manifest shows zero images?                      → Inspect the output dir directly; zip may contain
                                                   non-image files or nested folders
Zip is a Figma flow export?                      → Use figma-flow-pack skill instead
```

---

## Code Examples

### Example 1: Default flow (latest zip, auto output)

```bash
python3 /home/compean/.config/opencode/skills/downloads-zip-pack/assets/extract_latest.py
```

Output includes a list of absolute image paths. Feed those to the Read tool:

```
Source zip:   /home/compean/Downloads/drive-download-20260416T195107Z-3-001.zip
Extracted to: /tmp/zip-pack-drive-download-20260416T195107Z-3-001
Groups:       1
Images:       4
Manifest:     /tmp/zip-pack-drive-download-20260416T195107Z-3-001/manifest.txt

Absolute image paths (ready for Read tool):
  /tmp/zip-pack-drive-download-20260416T195107Z-3-001/IMG_8169.PNG
  /tmp/zip-pack-drive-download-20260416T195107Z-3-001/IMG_8170.PNG
  /tmp/zip-pack-drive-download-20260416T195107Z-3-001/IMG_8171.PNG
  /tmp/zip-pack-drive-download-20260416T195107Z-3-001/IMG_8172.PNG
```

Then in a single assistant turn, call the Read tool in parallel once per image path.

### Example 2: Specific zip path

```bash
python3 /home/compean/.config/opencode/skills/downloads-zip-pack/assets/extract_latest.py \
  --zip "/home/compean/Downloads/prayerlock-paywall.zip"
```

### Example 3: Custom output location (e.g. inside docs/ for permanent reference)

```bash
python3 /home/compean/.config/opencode/skills/downloads-zip-pack/assets/extract_latest.py \
  --zip "/home/compean/Downloads/prayerlock-paywall.zip" \
  --output "/home/compean/Development/myproject/docs/screens/prayerlock-paywall"
```

Use this when the user says "save these for reference" or when the screenshots will be
committed to a repo's docs folder.

---

## Commands

```bash
# Latest zip in ~/Downloads → /tmp/zip-pack-{stem}/
python3 /home/compean/.config/opencode/skills/downloads-zip-pack/assets/extract_latest.py

# Specific zip → /tmp/zip-pack-{stem}/
python3 /home/compean/.config/opencode/skills/downloads-zip-pack/assets/extract_latest.py --zip "/path/to/file.zip"

# Specific zip → custom output
python3 /home/compean/.config/opencode/skills/downloads-zip-pack/assets/extract_latest.py --zip "/path/to/file.zip" --output "/path/to/out"

# Different source directory (e.g. a ~/Screenshots inbox)
python3 /home/compean/.config/opencode/skills/downloads-zip-pack/assets/extract_latest.py --downloads "~/Screenshots"
```

---

## Resources

- **Templates**: See [assets/](assets/) for `extract_latest.py` (Python 3.8+, stdlib only).
- **Related skill**: `figma-flow-pack` — same extraction core, but biased toward
  Figma flow-level analysis (screen hierarchy, CTA placement, density). Use
  `figma-flow-pack` for Figma exports; use this skill for generic downloaded zips.
