#!/usr/bin/env python3
"""Start VerseGuard's Expo server after Herdr creates a linked worktree."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from dataclasses import dataclass
from typing import Any

PRIMARY_CHECKOUT = Path("/home/compean/development/VerseGuard")
EXPO_COMMAND = "npx expo start --clear --port 8082"


class WorkflowError(RuntimeError):
    """An error that should be shown to the user."""


@dataclass(frozen=True)
class Target:
    checkout: Path
    repo_root: Path
    label: str
    linked: bool


def object_at(value: Any, *keys: str) -> dict[str, Any]:
    for key in keys:
        if not isinstance(value, dict):
            return {}
        value = value.get(key)
    return value if isinstance(value, dict) else {}


def first_string(*values: Any) -> str | None:
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def first_bool(*values: Any) -> bool | None:
    for value in values:
        if isinstance(value, bool):
            return value
    return None


def parse_json_env(name: str, env: dict[str, str]) -> dict[str, Any]:
    raw = env.get(name)
    if not raw:
        raise WorkflowError(f"{name} is missing")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise WorkflowError(f"{name} is invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise WorkflowError(f"{name} must contain a JSON object")
    return value


def event_kind(event: dict[str, Any]) -> str | None:
    value = first_string(event.get("event"), object_at(event, "data").get("type"))
    return value.lower().replace(".", "_").replace("-", "_") if value else None


def target_from_workspace(workspace: dict[str, Any]) -> Target | None:
    worktree = object_at(workspace, "worktree")
    return make_target(
        first_string(worktree.get("checkout_path"), worktree.get("path")),
        first_string(worktree.get("repo_root")),
        first_string(worktree.get("branch"), worktree.get("label"), workspace.get("label")),
        first_bool(worktree.get("is_linked_worktree")),
    )


def target_from_event(event: dict[str, Any]) -> Target | None:
    kind = event_kind(event)
    if kind not in ("worktree_created", "workspace_created", "workspace_focused"):
        return None

    data = object_at(event, "data") or event
    workspace = object_at(data, "workspace")
    worktree = object_at(data, "worktree")
    workspace_target = target_from_workspace(workspace)
    if not worktree:
        return workspace_target
    workspace_worktree = object_at(workspace, "worktree")
    return make_target(
        first_string(
            worktree.get("path"),
            worktree.get("checkout_path"),
            workspace_worktree.get("checkout_path"),
        ),
        first_string(
            workspace_worktree.get("repo_root"),
            worktree.get("repo_root"),
            data.get("repo_root"),
        ),
        first_string(worktree.get("branch"), worktree.get("label"), workspace.get("label")),
        first_bool(
            workspace_worktree.get("is_linked_worktree"),
            worktree.get("is_linked_worktree"),
        ),
    )


def event_workspace_id(event: dict[str, Any]) -> str | None:
    data = object_at(event, "data") or event
    return first_string(
        data.get("workspace_id"),
        object_at(data, "workspace").get("workspace_id"),
        object_at(data, "worktree").get("open_workspace_id"),
        event.get("workspace_id"),
    )


def context_workspace_id(context: dict[str, Any]) -> str | None:
    return first_string(
        context.get("workspace_id"),
        object_at(context, "workspace").get("workspace_id"),
    )


def pane_runs_expo(pane: dict[str, Any]) -> bool:
    for key in ("terminal_title_stripped", "terminal_title"):
        value = pane.get(key)
        if isinstance(value, str) and EXPO_COMMAND in value:
            return True
    return False


def target_from_context(context: dict[str, Any]) -> Target | None:
    worktree = object_at(context, "worktree")
    workspace = object_at(context, "workspace")
    workspace_worktree = object_at(workspace, "worktree")
    checkout = first_string(
        worktree.get("checkout_path"),
        worktree.get("path"),
        workspace_worktree.get("checkout_path"),
        context.get("workspace_cwd"),
        context.get("focused_pane_cwd"),
    )
    repo_root = first_string(
        worktree.get("repo_root"),
        workspace_worktree.get("repo_root"),
        context.get("repo_root"),
    )
    linked = first_bool(
        worktree.get("is_linked_worktree"),
        workspace_worktree.get("is_linked_worktree"),
    )
    label = first_string(
        worktree.get("branch"),
        worktree.get("label"),
        context.get("workspace_label"),
    )
    return make_target(checkout, repo_root, label, linked)


def make_target(
    checkout: str | None,
    repo_root: str | None,
    label: str | None,
    linked: bool | None,
) -> Target | None:
    if not checkout or not repo_root:
        return None
    checkout_path = Path(checkout).expanduser().resolve(strict=False)
    repo_path = Path(repo_root).expanduser().resolve(strict=False)
    if label and label.startswith("refs/heads/"):
        label = label.removeprefix("refs/heads/")
    return Target(checkout_path, repo_path, label or checkout_path.name, linked is True)


def payload_items(payload: dict[str, Any], key: str) -> list[dict[str, Any]]:
    result = payload.get("result", payload)
    items = result.get(key, []) if isinstance(result, dict) else []
    return [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []


class Herdr:
    def __init__(self, env: dict[str, str]) -> None:
        self.bin = env.get("HERDR_BIN_PATH") or "herdr"
        self.env = env

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        try:
            result = subprocess.run(
                [self.bin, *args],
                env=self.env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except OSError as error:
            raise WorkflowError(f"could not run HERDR_BIN_PATH {self.bin!r}: {error}") from error
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip()
            raise WorkflowError(f"herdr {' '.join(args)} failed: {detail or f'exit {result.returncode}'}")
        return result

    def json(self, *args: str) -> dict[str, Any]:
        result = self.run(*args)
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise WorkflowError(f"herdr {' '.join(args)} returned invalid JSON: {error}") from error
        if not isinstance(payload, dict):
            raise WorkflowError(f"herdr {' '.join(args)} returned a non-object JSON response")
        if "error" in payload:
            raise WorkflowError(f"herdr {' '.join(args)} failed: {payload['error']}")
        return payload

    def notify(self, title: str, body: str) -> None:
        try:
            self.json("notification", "show", title, "--body", body, "--sound", "none")
        except WorkflowError as error:
            print(f"verseguard-worktree-server: notification failed: {error}", file=sys.stderr)

    def target_for_workspace(self, workspace_id: str) -> Target | None:
        get_error: WorkflowError | None = None
        try:
            payload = self.json("workspace", "get", workspace_id)
            result = payload.get("result", payload)
            workspace = result.get("workspace", {}) if isinstance(result, dict) else {}
            if isinstance(workspace, dict):
                target = target_from_workspace(workspace)
                if target is not None:
                    return target
        except WorkflowError as error:
            get_error = error

        for workspace in payload_items(self.json("workspace", "list"), "workspaces"):
            if workspace.get("workspace_id") == workspace_id:
                return target_from_workspace(workspace)
        if get_error is not None:
            raise get_error
        return None

    def has_expo_tab(self, workspace_id: str) -> bool:
        for pane in payload_items(
            self.json("pane", "list", "--workspace", workspace_id), "panes"
        ):
            if pane_runs_expo(pane):
                return True
        return False

    def create_server_tab(self, workspace_id: str, target: Target) -> None:
        payload = self.json(
            "tab",
            "create",
            "--workspace",
            workspace_id,
            "--cwd",
            str(target.checkout),
            "--label",
            target.label,
            "--no-focus",
        )
        result = payload.get("result", payload)
        root_pane = result.get("root_pane", {}) if isinstance(result, dict) else {}
        pane_id = root_pane.get("pane_id") if isinstance(root_pane, dict) else None
        if not isinstance(pane_id, str) or not pane_id:
            raise WorkflowError("herdr tab create response did not include result.root_pane.pane_id")
        try:
            # Herdr 0.8's pane run is successful with empty stdout, unlike the
            # JSON-producing workspace/tab/pane-list commands.
            self.run("pane", "run", pane_id, EXPO_COMMAND)
        except WorkflowError:
            tab = result.get("tab", {}) if isinstance(result, dict) else {}
            tab_id = tab.get("tab_id") if isinstance(tab, dict) else None
            if isinstance(tab_id, str):
                try:
                    self.json("tab", "close", tab_id)
                except WorkflowError as cleanup_error:
                    print(
                        f"verseguard-worktree-server: could not close failed server tab: {cleanup_error}",
                        file=sys.stderr,
                    )
            raise


def run_npm_ci(target: Target, env: dict[str, str]) -> None:
    try:
        result = subprocess.run(
            ["npm", "ci"],
            cwd=target.checkout,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise WorkflowError(f"could not run npm ci in {target.checkout}: {error}") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise WorkflowError(f"npm ci failed in {target.checkout}: {detail or f'exit {result.returncode}'}")


def lock_path(target: Target, env: dict[str, str]) -> Path:
    state_dir = Path(env.get("HERDR_PLUGIN_STATE_DIR") or "/tmp")
    state_dir.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(os.fsencode(target.checkout)).hexdigest()[:16]
    return state_dir / f"checkout-{digest}.lock"


def run_workflow(target: Target, herdr: Herdr, env: dict[str, str], workspace_id: str) -> None:
    if target.repo_root != PRIMARY_CHECKOUT.resolve(strict=False) or not target.linked:
        return
    if target.checkout == target.repo_root:
        return
    if not target.checkout.is_dir():
        raise WorkflowError(f"worktree checkout does not exist: {target.checkout}")

    with lock_path(target, env).open("a+") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        if herdr.has_expo_tab(workspace_id):
            message = f"A server tab already exists for {target.checkout}; not launching another."
            print(f"verseguard-worktree-server: {message}", file=sys.stderr)
            return

        run_npm_ci(target, env)

        # Re-check after npm ci while holding the checkout lock. This also avoids
        # duplicating a tab created independently while installation was running.
        if herdr.has_expo_tab(workspace_id):
            message = f"A server tab appeared for {target.checkout}; not launching another."
            print(f"verseguard-worktree-server: {message}", file=sys.stderr)
            return
        herdr.create_server_tab(workspace_id, target)


def main(argv: list[str] | None = None, env: dict[str, str] | None = None) -> int:
    argv = argv or sys.argv[1:]
    env = dict(os.environ if env is None else env)
    herdr = Herdr(env)
    try:
        workspace_id: str | None = None
        if argv == ["event"]:
            event = parse_json_env("HERDR_PLUGIN_EVENT_JSON", env)
            kind = event_kind(event)
            target = target_from_event(event)
            workspace_id = event_workspace_id(event)
            if target is None and kind in ("workspace_created", "workspace_focused"):
                if not workspace_id:
                    raise WorkflowError(f"{kind} event did not include a workspace id")
                target = herdr.target_for_workspace(workspace_id)
            # workspace events fire for ordinary and primary workspaces too.
            if target is None and kind in ("workspace_created", "workspace_focused"):
                return 0
        elif argv == ["retry"]:
            context = parse_json_env("HERDR_PLUGIN_CONTEXT_JSON", env)
            target = target_from_context(context)
            workspace_id = context_workspace_id(context)
        else:
            raise WorkflowError("usage: verseguard_server.py event|retry")
        if target is None:
            raise WorkflowError("could not resolve the selected worktree and its primary checkout")
        if not workspace_id:
            raise WorkflowError("could not resolve the worktree workspace")
        run_workflow(target, herdr, env, workspace_id)
        return 0
    except (WorkflowError, OSError) as error:
        message = str(error)
        print(f"verseguard-worktree-server: {message}", file=sys.stderr)
        herdr.notify("VerseGuard worktree server failed", message)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
