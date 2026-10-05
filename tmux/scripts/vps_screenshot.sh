#!/usr/bin/env bash
set -euo pipefail

# Capture an active Hyprland window (or a mouse-selected region with --region)
# locally, upload it directly to the VPS, then replace the Wayland clipboard with
# the image's VPS path. This makes the next Ctrl+V inside a remote Pi session
# paste a path the VPS can actually read.

ssh_target="${PI_SCREENSHOT_SSH_TARGET:-compean@dev-vps}"
ssh_key="${PI_SCREENSHOT_SSH_KEY:-$HOME/.ssh/id_ed25519_vps_screenshot}"
remote_dir="${PI_SCREENSHOT_REMOTE_DIR:-/home/compean/uploads/moshi}"
local_dir="${PI_SCREENSHOT_LOCAL_DIR:-$HOME/Pictures/Screenshots}"

edit_before_upload=false
select_region=false
for arg in "$@"; do
  case "$arg" in
    -e | --edit) edit_before_upload=true ;;
    -r | --region) select_region=true ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

notify() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name="VPS Screenshot" "$1" "${2:-}"
  fi
}

dependencies=(grim hyprctl jq ssh wl-copy)
$edit_before_upload && dependencies+=(tensaku)
$select_region && dependencies+=(slurp)

for dependency in "${dependencies[@]}"; do
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
if $select_region; then
  filename="pi-region-$(date +%Y%m%d-%H%M%S-%N).png"
else
  filename="pi-window-$(date +%Y%m%d-%H%M%S-%N).png"
fi
local_path="$local_dir/$filename"
remote_path="$remote_dir/$filename"

# Capture directly using the same Hyprland geometry and grim primitives that
# Hyprshot uses internally. This avoids a clipboard read-back race while still
# leaving the captured image in the clipboard on upload error.
if $select_region; then
  # slurp exits non-zero (and prints nothing) when the selection is cancelled
  # with Escape or right-click, which is a deliberate abort, not a failure.
  if ! geometry=$(slurp) || [[ -z "$geometry" ]]; then
    notify "Screenshot cancelled" "No region was selected"
    exit 0
  fi
  subject="the selected region"
else
  if ! geometry=$(hyprctl -j activewindow | jq -er '
    select(.at[0] != null and .at[1] != null and .size[0] > 0 and .size[1] > 0)
    | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"
  '); then
    notify "Screenshot failed" "Hyprland did not report an active window"
    exit 1
  fi
  subject="the active window"
fi

if ! grim -g "$geometry" "$local_path" || [[ ! -s "$local_path" ]]; then
  rm -f "$local_path"
  notify "Screenshot failed" "grim could not capture $subject"
  printf 'Could not capture geometry: %s\n' "$geometry" >&2
  exit 1
fi

# Annotate before upload. Tensaku writes back over the same file on save, so an
# unchanged mtime means the editor was dismissed and nothing should be shared.
if $edit_before_upload; then
  mtime_before=$(stat -c %Y "$local_path")

  if ! tensaku \
    --filename "$local_path" \
    --output-filename "$local_path" \
    --actions-on-enter save-to-file \
    --actions-on-escape exit \
    --early-exit
  then
    rm -f "$local_path"
    notify "Screenshot cancelled" "The annotation editor exited with an error"
    exit 1
  fi

  if [[ $(stat -c %Y "$local_path") == "$mtime_before" ]]; then
    rm -f "$local_path"
    notify "Screenshot discarded" "No annotation was saved, so nothing was uploaded"
    exit 0
  fi
fi

if ! wl-copy --type image/png < "$local_path"; then
  notify "Screenshot failed" "Could not copy the captured image"
  exit 1
fi

# The dedicated key is forced server-side into an upload-only wrapper. It has
# no shell, PTY, forwarding, or arbitrary-command access.
remote_command="upload $filename"
# -F /dev/null: ~/.ssh/config has a "Host *" IdentityFile, and IdentitiesOnly
# does not exclude config identities, so the default key would otherwise win the
# handshake and bypass this key's forced upload-only command.
if ! ssh \
  -F /dev/null \
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
