#!/bin/bash
set -euo pipefail

ssh_target="${PI_SCREENSHOT_SSH_TARGET:-compean@dev-vps}"
ssh_key="${PI_SCREENSHOT_SSH_KEY:-$HOME/.ssh/id_ed25519_vps_screenshot}"
remote_dir="${PI_SCREENSHOT_REMOTE_DIR:-/home/compean/uploads/moshi}"
local_dir="${PI_SCREENSHOT_LOCAL_DIR:-$HOME/Pictures/Screenshots}"
screencapture_bin="${PI_SCREENSHOT_SCREENCAPTURE_BIN:-/usr/sbin/screencapture}"
ssh_bin="${PI_SCREENSHOT_SSH_BIN:-/usr/bin/ssh}"
pbcopy_bin="${PI_SCREENSHOT_PBCOPY_BIN:-/usr/bin/pbcopy}"
osascript_bin="${PI_SCREENSHOT_OSASCRIPT_BIN:-/usr/bin/osascript}"

notify() {
  "$osascript_bin" - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run arguments
  display notification (item 2 of arguments) with title (item 1 of arguments)
end run
APPLESCRIPT
}

for dependency in "$screencapture_bin" "$ssh_bin" "$pbcopy_bin" "$osascript_bin"; do
  if [[ ! -x $dependency ]]; then
    notify "VPS screenshot unavailable" "Missing command: $dependency"
    printf 'Missing required command: %s\n' "$dependency" >&2
    exit 1
  fi
done

if [[ ! -r $ssh_key ]]; then
  notify "VPS upload unavailable" "Missing screenshot key: $ssh_key"
  printf 'Missing screenshot upload key: %s\n' "$ssh_key" >&2
  exit 1
fi

mkdir -p "$local_dir"
printf -v suffix '%09d' $(((RANDOM * 32768 + RANDOM) % 1000000000))
filename="pi-window-$(date +%Y%m%d-%H%M%S)-$suffix.png"
local_path="$local_dir/$filename"
remote_path="$remote_dir/$filename"

# This is the native macOS interactive capture UI: drag to select a region, or
# press Space and click a window. Escape cancels without uploading anything.
if ! "$screencapture_bin" -i -t png "$local_path" || [[ ! -s $local_path ]]; then
  rm -f "$local_path"
  exit 0
fi

# Preserve a useful local image clipboard until the restricted upload succeeds.
if ! "$osascript_bin" - "$local_path" <<'APPLESCRIPT' >/dev/null
on run arguments
  set imageFile to POSIX file (item 1 of arguments)
  set the clipboard to (read imageFile as «class PNGf»)
end run
APPLESCRIPT
then
  notify "Screenshot failed" "Could not copy the captured image"
  exit 1
fi

remote_command="upload $filename"
if ! "$ssh_bin" \
  -i "$ssh_key" \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -T "$ssh_target" \
  "$remote_command" < "$local_path"
then
  notify "VPS upload failed" "$ssh_target — local image remains in clipboard"
  printf 'Failed to upload %s to %s\n' "$local_path" "$ssh_target" >&2
  exit 1
fi

printf '%s' "$remote_path" | "$pbcopy_bin"
notify "VPS screenshot ready" "$remote_path"
printf '%s\n' "$remote_path"
