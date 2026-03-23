#!/usr/bin/env bash
set -u

EVENT="${1:-completed}"
SESSION_ID="${2:-}"
ERROR_TEXT="${3:-}"
REQUEST_ID="${4:-}"

BACKEND="${OPENCODE_NOTIFY_BACKEND:-auto}" # auto|notify-send|hyprctl
TIMEOUT_MS="${OPENCODE_NOTIFY_TIMEOUT_MS:-8000}"
COOLDOWN_MS="${OPENCODE_NOTIFY_COOLDOWN_MS:-2500}"
TITLE="${OPENCODE_NOTIFY_TITLE:-OpenCode}"

STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_DIR="${STATE_BASE}/opencode-notify"
STATE_FILE="${STATE_DIR}/last.tsv"

init_state_dir() {
  if mkdir -p "$STATE_DIR" 2>/dev/null; then
    if touch "$STATE_FILE" 2>/dev/null; then
      return 0
    fi
  else
    :
  fi

  STATE_DIR="/tmp/opencode-notify-${UID}"
  STATE_FILE="${STATE_DIR}/last.tsv"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  touch "$STATE_FILE" 2>/dev/null || true
}

now_ms() {
  local s
  s="$(date +%s)"
  printf '%s' "$((s * 1000))"
}

short_session() {
  local v="$1"
  [[ -z "$v" ]] && return 0
  printf '%s' "${v:0:8}"
}

truncate_text() {
  local text="$1"
  local max="${2:-140}"
  if (( ${#text} <= max )); then
    printf '%s' "$text"
    return 0
  fi
  printf '%s…' "${text:0:max}"
}

notify_via_notify_send() {
  local body="$1"
  command -v notify-send >/dev/null 2>&1 || return 1
  notify-send -t "$TIMEOUT_MS" "$TITLE" "$body"
}

notify_via_hyprctl() {
  local body="$1"
  command -v hyprctl >/dev/null 2>&1 || return 1
  # hyprctl notify ICON TIME_MS COLOR MESSAGE
  hyprctl notify -1 "$TIMEOUT_MS" "rgb(88cc88)" "$TITLE: $body" >/dev/null 2>&1
}

should_skip_cooldown() {
  local key="$1"
  local now last_ts last_key
  now="$(now_ms)"

  if [[ ! -r "$STATE_FILE" || ! -w "$STATE_FILE" ]]; then
    STATE_DIR="/tmp/opencode-notify-${UID}"
    STATE_FILE="${STATE_DIR}/last.tsv"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    touch "$STATE_FILE" 2>/dev/null || true
  fi

  if IFS=$'\t' read -r last_ts last_key < "$STATE_FILE" 2>/dev/null; then
    [[ -z "${last_ts:-}" ]] && last_ts=0
    [[ -z "${last_key:-}" ]] && last_key=""
    if [[ "$key" == "$last_key" ]] && (( now - last_ts < COOLDOWN_MS )); then
      return 0
    fi
  fi

  { printf '%s\t%s\n' "$now" "$key" > "$STATE_FILE"; } 2>/dev/null || true
  return 1
}

build_body() {
  local sid short err
  sid="$1"
  short="$(short_session "$sid")"
  err="$(truncate_text "${ERROR_TEXT:-}" 160)"

  case "$EVENT" in
    permission_ask)
      if [[ -n "$err" ]]; then
        printf 'Permission needed: %s (%s)' "$err" "${short:-no-id}"
      else
        printf 'Permission needed (%s)' "${short:-no-id}"
      fi
      ;;
    error)
      if [[ -n "$err" ]]; then
        printf 'Session error (%s): %s' "${short:-no-id}" "$err"
      else
        printf 'Session error (%s)' "${short:-no-id}"
      fi
      ;;
    completed|session_completed|done)
      if [[ -n "$short" ]]; then
        printf 'Response finished (%s)' "$short"
      else
        printf 'Response finished'
      fi
      ;;
    *)
      printf '%s (%s)' "$EVENT" "${short:-no-id}"
      ;;
  esac
}

main() {
  local key body ok
  init_state_dir
  if [[ -n "$REQUEST_ID" ]]; then
    key="${EVENT}:${REQUEST_ID}"
  else
    key="${EVENT}:${SESSION_ID:-none}"
  fi

  if should_skip_cooldown "$key"; then
    exit 0
  fi

  body="$(build_body "$SESSION_ID")"
  ok=1

  case "$BACKEND" in
    notify-send)
      notify_via_notify_send "$body" && ok=0 || ok=1
      ;;
    hyprctl)
      notify_via_hyprctl "$body" && ok=0 || ok=1
      ;;
    auto|*)
      if notify_via_notify_send "$body"; then
        ok=0
      elif notify_via_hyprctl "$body"; then
        ok=0
      else
        ok=1
      fi
      ;;
  esac

  # Never fail caller on notification issues
  [[ "$ok" -eq 0 ]] || true
  exit 0
}

main "$@"
