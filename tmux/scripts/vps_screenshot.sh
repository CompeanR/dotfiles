#!/usr/bin/env bash
set -euo pipefail

# Capture an active Hyprland window locally, upload it directly to the VPS,
# then replace the Wayland clipboard with the image's VPS path. This makes the
# next Ctrl+V inside a remote Pi session paste a path the VPS can actually read.

ssh_target="${PI_SCREENSHOT_SSH_TARGET:-compean@dev-vps}"
ssh_key="${PI_SCREENSHOT_SSH_KEY:-$HOME/.ssh/id_ed25519_vps_screenshot}"
remote_dir="${PI_SCREENSHOT_REMOTE_DIR:-/home/compean/uploads/moshi}"
local_dir="${PI_SCREENSHOT_LOCAL_DIR:-$HOME/Pictures/Screenshots}"

notify() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name="VPS Screenshot" "$1" "${2:-}"
  fi
}

for dependency in grim hyprctl jq ssh wl-copy; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    notify "Screenshot upload unavailable" "Missing command: $dependency"
    printf 'Missing required command: %s\n' "$dependency" >&2
    exit 127
  fi
done

if [[ ! -r "$ssh_key" ]]; then
  notify "VPS upload unavailable" "Missing screenshot key: $ssh_key"
  printf 'Missing screenshot upload key: %s\n' "$ssh_key" >&2
  exit 1
fi

mkdir -p "$local_dir"
filename="pi-window-$(date +%Y%m%d-%H%M%S-%N).png"
local_path="$local_dir/$filename"
remote_path="$remote_dir/$filename"

# Capture the active window directly using the same Hyprland geometry and grim
# primitives that Hyprshot uses internally. This avoids a clipboard read-back
# race while still leaving the captured image in the clipboard on upload error.
if ! geometry=$(hyprctl -j activewindow | jq -er '
  select(.at[0] != null and .at[1] != null and .size[0] > 0 and .size[1] > 0)
  | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"
'); then
  notify "Screenshot failed" "Hyprland did not report an active window"
  exit 1
fi

if ! grim -g "$geometry" "$local_path" || [[ ! -s "$local_path" ]]; then
  rm -f "$local_path"
  notify "Screenshot failed" "grim could not capture the active window"
  printf 'Could not capture active-window geometry: %s\n' "$geometry" >&2
  exit 1
fi

if ! wl-copy --type image/png < "$local_path"; then
  notify "Screenshot failed" "Could not copy the captured image"
  exit 1
fi

# The dedicated key is forced server-side into an upload-only wrapper. It has
# no shell, PTY, forwarding, or arbitrary-command access.
remote_command="upload $filename"
if ! ssh \
  -i "$ssh_key" \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -T "$ssh_target" \
  "$remote_command" < "$local_path"
then
  notify "VPS upload failed" "$ssh_target — local image remains in clipboard"
  printf 'Failed to upload %s to %s:%s\n' "$local_path" "$ssh_target" "$remote_path" >&2
  exit 1
fi

# Only replace the image clipboard after the remote upload is complete.
printf '%s' "$remote_path" | wl-copy --type text/plain
notify "VPS screenshot ready" "$remote_path"
printf '%s\n' "$remote_path"
