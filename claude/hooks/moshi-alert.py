#!/usr/bin/env python3
"""Moshi push alerts for Claude Code, mirroring pi/extensions/moshi-completion-alert.ts.

Hook mode (stdin JSON from Claude Code):
  UserPromptSubmit  records when the turn started
  Stop              pushes if the turn ran >= MOSHI_LONG_TURN_SECONDS, or push-always/push-next is set
  Notification      pushes only for types listed in MOSHI_NOTIFY_TYPES (e.g. permission_prompt,idle_prompt)

CLI mode:
  moshi-alert.py on|off|next|cancel|status
"""

import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

WEBHOOK_URL = "https://api.getmoshi.app/api/webhook"
DEFAULT_LONG_TURN_SECONDS = 1200
MAX_MESSAGE_LENGTH = 220

HOME = Path.home()
CONFIG_DIR = HOME / ".config" / "moshi"
TOKEN_FILE = Path(os.environ.get("MOSHI_PUSH_TOKEN_FILE", CONFIG_DIR / "push-token"))
ALWAYS_FILE = CONFIG_DIR / "push-always"
NEXT_FILE = CONFIG_DIR / "claude-push-next"
STATE_DIR = HOME / ".local" / "state" / "moshi"
TURNS_DIR = STATE_DIR / "claude-turns"
LOG_FILE = STATE_DIR / "completion-alert.log"


def threshold_seconds():
    try:
        value = float(os.environ.get("MOSHI_LONG_TURN_SECONDS", DEFAULT_LONG_TURN_SECONDS))
        return value if value >= 0 else DEFAULT_LONG_TURN_SECONDS
    except ValueError:
        return DEFAULT_LONG_TURN_SECONDS


def notify_types():
    raw = os.environ.get("MOSHI_NOTIFY_TYPES", "")
    return {t.strip() for t in raw.split(",") if t.strip()}


def truncate(value, limit=MAX_MESSAGE_LENGTH):
    normalized = " ".join(value.split())
    return normalized if len(normalized) <= limit else normalized[: limit - 1] + "…"


def format_duration(seconds):
    total = max(0, round(seconds))
    if total < 60:
        return f"{total}s"
    minutes, rest = divmod(total, 60)
    return f"{minutes}m" if rest == 0 else f"{minutes}m {rest}s"


def write_log(level, event, **details):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "level": level,
            "event": event,
            "agent": "claude",
            **details,
        }
        with open(LOG_FILE, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")
        os.chmod(LOG_FILE, 0o600)
    except OSError:
        pass


def send_push(title, message, reason):
    try:
        token = TOKEN_FILE.read_text(encoding="utf-8").strip()
        if not token:
            raise ValueError("push token file is empty")
        body = json.dumps(
            {"token": token, "title": truncate(title, 100), "message": truncate(message)}
        ).encode()
        request = urllib.request.Request(
            WEBHOOK_URL,
            data=body,
            headers={"Content-Type": "application/json", "User-Agent": "moshi-alert/1.0"},
        )
        with urllib.request.urlopen(request, timeout=10):
            pass
        write_log("info", "push_sent", reason=reason, title=truncate(title, 100))
    except Exception as error:
        write_log("error", "push_failed", reason=reason, error=str(error))


def turn_file(session_id):
    return TURNS_DIR / f"{session_id}.json"


def last_assistant_text(transcript_path):
    try:
        lines = Path(transcript_path).read_text(encoding="utf-8").splitlines()
    except (OSError, TypeError):
        return ""
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("type") != "assistant":
            continue
        content = entry.get("message", {}).get("content", [])
        if isinstance(content, str):
            return content
        text = " ".join(
            part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text"
        ).strip()
        if text:
            return text
    return ""


def on_prompt(event):
    session_id = event.get("session_id")
    if not session_id:
        return
    TURNS_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = turn_file(session_id)
    path.write_text(json.dumps({"started": time.time(), "prompt": event.get("prompt", "")}))
    os.chmod(path, 0o600)


def on_stop(event):
    session_id = event.get("session_id")
    if not session_id:
        return
    path = turn_file(session_id)
    try:
        turn = json.loads(path.read_text())
    except (OSError, ValueError):
        turn = None
    path.unlink(missing_ok=True)

    push_next = NEXT_FILE.exists()
    push_always = ALWAYS_FILE.exists()
    elapsed = time.time() - turn["started"] if turn else 0
    long_running = turn is not None and elapsed >= threshold_seconds()
    if push_next:
        NEXT_FILE.unlink(missing_ok=True)
    if not (push_next or push_always or long_running):
        return

    project = Path(event.get("cwd") or os.getcwd()).name or "Claude"
    reason = "push-always" if push_always else "push-next" if push_next else "long-turn"
    prompt = (turn or {}).get("prompt", "").strip()
    detail = (
        event.get("last_assistant_message")
        or last_assistant_text(event.get("transcript_path"))
        or (f"Finished: {prompt}" if prompt else "Claude finished its turn")
    )
    send_push(f"{project}: Claude completed in {format_duration(elapsed)}", detail, reason)


def on_notification(event):
    kind = event.get("notification_type", "")
    if kind not in notify_types():
        return
    project = Path(event.get("cwd") or os.getcwd()).name or "Claude"
    send_push(f"{project}: Claude needs you", event.get("message") or kind, kind)


def run_hook():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return
    handlers = {
        "UserPromptSubmit": on_prompt,
        "Stop": on_stop,
        "Notification": on_notification,
    }
    handler = handlers.get(event.get("hook_event_name"))
    if handler:
        handler(event)


def run_cli(action):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    if action == "on":
        ALWAYS_FILE.write_text("on\n")
        os.chmod(ALWAYS_FILE, 0o600)
    elif action == "off":
        ALWAYS_FILE.unlink(missing_ok=True)
    elif action == "next":
        NEXT_FILE.write_text("on\n")
    elif action == "cancel":
        NEXT_FILE.unlink(missing_ok=True)
    elif action != "status":
        print("Usage: moshi-alert.py on|off|next|cancel|status", file=sys.stderr)
        return 1
    print(
        f"push after every turn: {'on' if ALWAYS_FILE.exists() else 'off'}\n"
        f"next Claude turn: {'armed' if NEXT_FILE.exists() else 'off'}\n"
        f"long-turn threshold: {format_duration(threshold_seconds())}\n"
        f"notification types: {', '.join(sorted(notify_types())) or 'none'}"
    )
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1:
        sys.exit(run_cli(sys.argv[-1].lower()))
    try:
        run_hook()
    except Exception as error:
        write_log("error", "hook_failed", error=str(error))
