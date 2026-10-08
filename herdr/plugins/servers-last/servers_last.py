import json
import os
import socket

LABEL = "servers"


def call(method, params=None):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.connect(os.environ["HERDR_SOCKET_PATH"])
        sock.sendall(json.dumps({"id": "servers-last", "method": method, "params": params or {}}).encode() + b"\n")
        data = b""
        while not data.endswith(b"\n"):
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data)["result"]


def main():
    workspaces = call("workspace.list")["workspaces"]
    ids = [w["workspace_id"] for w in workspaces if w["label"] == LABEL]
    if ids and workspaces[-1]["workspace_id"] != ids[0]:
        call("workspace.move", {"workspace_id": ids[0], "insert_index": len(workspaces)})


if __name__ == "__main__":
    main()
