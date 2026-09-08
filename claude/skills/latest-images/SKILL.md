---
name: latest-images
description: Retrieve the latest N images the user sent via Taildrop (e.g. a batch of iPhone screenshots) as local file paths, without asking for paths. Use when the user says they sent/uploaded several images, references "the latest N" uploads, or wants a batch of screenshots analyzed. For a single image the existing `/image` skill is fine; use this when there is more than one, when capture order matters, or when the plain `list` was polluted by `pi-window-*` remote-viewer screen grabs.
---

# Latest Taildrop images (batch)

Fetch the most recent image uploads and read them. Default source is all user uploads
(everything except `pi-window-*` remote-viewer screen grabs).

## Run

```bash
python3 "/home/compean/.claude/skills/latest-images/latest-images.py" <COUNT> [--type user|iphone|window|other|all] [--order oldest|newest]
```

- **COUNT** — how many of the latest images to return (default `1`). For a set the user
  just sent, pass the count they mention (e.g. `6`).
- **`--type`** (default `user`) — source filter:
  - `user` → all user uploads except `pi-window-*` grabs (default). Includes `IMG_*` device captures and timestamp-named screenshots alike.
  - `iphone` → only device camera-roll captures named `IMG_*`.
  - `window` → moshi `pi-window-*` remote-viewer screen grabs.
  - `other` → images whose names match neither `IMG_*` nor `pi-window-*`.
  - `all` → any image, newest by modified time regardless of name.
- **COUNT must be >= 1** (0/negative is rejected). Paths are always printed absolute,
  even with a relative `--dir`. `HEIC/HEIF/TIFF` are listed if present but may not be
  readable by the Read tool — prefer PNG/JPG sources.
- **`--order`** (default `oldest`) — order of the returned batch. `oldest` returns them
  oldest-first so a set of N screenshots maps cleanly to shot 1..N in capture order;
  `newest` returns newest-first.
- **`--dir`** — override the upload directory (repeatable). Default is `~/uploads/moshi`.

The script prints **one absolute path per line**. Read each with the Read tool (they can be
read in parallel), then answer the user's request. If no analysis request was given, briefly
describe each image and transcribe important visible text.

## Rules

- Do not modify or delete the received images.
- If the script errors or finds nothing, report its exact stderr and the directory it
  searched — do not guess about the images.
- Reading many images in one turn can trip the Pi routing gate after ~10 solo tool calls;
  if it does, make the required delegation, then continue reading.

## Examples

```bash
# The user says "the latest 6 are the screenshots" — grab that batch in capture order:
python3 "/home/compean/.claude/skills/latest-images/latest-images.py" 6

# Just the single newest upload of any kind:
python3 "/home/compean/.claude/skills/latest-images/latest-images.py" 1 --type all

# The last 3 remote-viewer screen grabs, newest first:
python3 "/home/compean/.claude/skills/latest-images/latest-images.py" 3 --type window --order newest
```
