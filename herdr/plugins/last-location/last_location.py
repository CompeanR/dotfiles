import json
import os
import subprocess
import sys
from pathlib import Path

HERDR = os.environ.get("HERDR_BIN_PATH") or "herdr"
STATE = Path(os.environ.get("HERDR_PLUGIN_STATE_DIR") or "/tmp") / "last-location.json"


def herdr(*args):
    out = subprocess.run([HERDR, *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out[out.find("{"):])["result"]


def load():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def main():
    tabs = herdr("tab", "list")["tabs"]
    focused = next((t["tab_id"] for t in tabs if t["focused"]), None)
    state = load()
    if focused and focused != state.get("curr"):
        state = {"prev": state.get("curr"), "curr": focused}
        STATE.parent.mkdir(parents=True, exist_ok=True)
        STATE.write_text(json.dumps(state))

    prev = state.get("prev")
    if sys.argv[1:] == ["toggle"] and prev and prev != focused and any(t["tab_id"] == prev for t in tabs):
        herdr("tab", "focus", prev)


if __name__ == "__main__":
    main()
