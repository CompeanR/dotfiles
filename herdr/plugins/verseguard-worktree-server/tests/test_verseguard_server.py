from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PLUGIN_DIR = Path(__file__).resolve().parents[1]
SCRIPT = PLUGIN_DIR / "verseguard_server.py"
CANONICAL_EVENT = Path(__file__).parent / "fixtures" / "worktree-created.json"
spec = importlib.util.spec_from_file_location("verseguard_server", SCRIPT)
assert spec and spec.loader
plugin = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = plugin
spec.loader.exec_module(plugin)

PRIMARY = "/home/compean/development/VerseGuard"


class FakeEnvironment:
    def __init__(
        self, duplicate: bool = False, npm_exit: int = 0, checkout_name: str = "feature-one"
    ) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.checkout = self.root / checkout_name
        self.checkout.mkdir()
        self.log = self.root / "calls.jsonl"
        self.herdr = self.root / "fake-herdr"
        self.npm = self.root / "npm"
        self.herdr.write_text(
            """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['FAKE_CALL_LOG'], 'a') as out:
    out.write(json.dumps({'tool': 'herdr', 'args': args}) + '\\n')
checkout = os.environ['FAKE_CHECKOUT']
workspace = {
    'workspace_id': args[2] if args[:2] == ['workspace', 'get'] else 'w-worktree',
    'label': os.environ.get('FAKE_WORKSPACE_LABEL', 'feature-one'),
    'worktree': {
        'checkout_path': checkout,
        'repo_root': os.environ.get('FAKE_REPO_ROOT'),
        'is_linked_worktree': True,
    },
}
if args[:2] == ['workspace', 'get'] and len(args) == 3:
    result = {'type': 'workspace_info', 'workspace': workspace}
elif args == ['workspace', 'list']:
    result = {'type': 'workspace_list', 'workspaces': [
        workspace,
        {'workspace_id': 'w-other', 'label': 'code'},
        {'workspace_id': 'w-servers', 'label': 'servers'},
    ]}
elif args[:2] == ['pane', 'list']:
    workspace_id = args[args.index('--workspace') + 1] if '--workspace' in args else 'unknown'
    panes = [{
        'pane_id': f'{workspace_id}:p-code',
        'tab_id': f'{workspace_id}:t1',
        'cwd': checkout,
        'terminal_title': 'claude',
        'terminal_title_stripped': 'claude',
    }]
    if os.environ.get('FAKE_DUPLICATE') == '1':
        panes.append({
            'pane_id': f'{workspace_id}:p-expo',
            'tab_id': f'{workspace_id}:t-expo',
            'cwd': checkout,
            'terminal_title': 'npx expo start --clear --port 8082',
            'terminal_title_stripped': 'npx expo start --clear --port 8082',
        })
    result = {'type': 'pane_list', 'panes': panes}
elif args[:2] == ['tab', 'create']:
    workspace_id = args[args.index('--workspace') + 1]
    result = {'type': 'tab_created', 'tab': {'tab_id': f'{workspace_id}:t-new'}, 'root_pane': {'pane_id': f'{workspace_id}:p-new'}}
elif args[:2] == ['pane', 'run']:
    # Herdr 0.8 performs pane run successfully without writing JSON/stdout.
    sys.exit(0)
elif args[:2] == ['notification', 'show']:
    result = {'type': 'notification_shown'}
elif args[:2] == ['tab', 'close']:
    result = {'type': 'tab_closed'}
else:
    print(json.dumps({'error': {'message': 'unexpected fake call: ' + repr(args)}}))
    sys.exit(2)
print(json.dumps({'id': 'fake', 'result': result}))
"""
        )
        self.npm.write_text(
            """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_CALL_LOG'], 'a') as out:
    out.write(json.dumps({'tool': 'npm', 'args': sys.argv[1:], 'cwd': os.getcwd()}) + '\\n')
sys.exit(int(os.environ.get('FAKE_NPM_EXIT', '0')))
"""
        )
        self.herdr.chmod(0o755)
        self.npm.chmod(0o755)
        self.env = {
            **os.environ,
            "HERDR_BIN_PATH": str(self.herdr),
            "HERDR_PLUGIN_STATE_DIR": str(self.root / "state"),
            "FAKE_CALL_LOG": str(self.log),
            "FAKE_CHECKOUT": str(self.checkout),
            "FAKE_DUPLICATE": "1" if duplicate else "0",
            "FAKE_NPM_EXIT": str(npm_exit),
            "FAKE_REPO_ROOT": PRIMARY,
            "FAKE_WORKSPACE_LABEL": checkout_name,
            "PATH": f"{self.root}:{os.environ.get('PATH', '')}",
        }

    def event(self, repo_root: str = PRIMARY) -> dict:
        raw = CANONICAL_EVENT.read_text()
        return json.loads(
            raw.replace("$PRIMARY", repo_root).replace("$WORKTREE", str(self.checkout))
        )

    def run_event(
        self, repo_root: str = PRIMARY, payload: dict | None = None
    ) -> subprocess.CompletedProcess[str]:
        event = payload if payload is not None else self.event(repo_root)
        env = {**self.env, "HERDR_PLUGIN_EVENT_JSON": json.dumps(event)}
        return subprocess.run(
            [sys.executable, str(SCRIPT), "event"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def run_focused(self, workspace_id: str = "w-dashboard") -> subprocess.CompletedProcess[str]:
        return self.run_event(
            payload={
                "event": "workspace_focused",
                "data": {"type": "workspace_focused", "workspace_id": workspace_id},
            }
        )

    def run_retry(self, workspace_id: str = "w-selected") -> subprocess.CompletedProcess[str]:
        context = {
            "workspace_id": workspace_id,
            "workspace_label": self.env["FAKE_WORKSPACE_LABEL"],
            "worktree": {
                "checkout_path": str(self.checkout),
                "repo_root": self.env["FAKE_REPO_ROOT"],
                "is_linked_worktree": True,
            },
        }
        env = {**self.env, "HERDR_PLUGIN_CONTEXT_JSON": json.dumps(context)}
        return subprocess.run(
            [sys.executable, str(SCRIPT), "retry"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def close(self) -> None:
        self.temp.cleanup()


class ManifestTests(unittest.TestCase):
    def test_does_not_run_on_every_workspace_focus(self) -> None:
        manifest = (PLUGIN_DIR / "herdr-plugin.toml").read_text()
        self.assertNotIn('on = "workspace.focused"', manifest)


class ParsingTests(unittest.TestCase):
    def test_parses_exact_canonical_underscore_worktree_created_fixture(self) -> None:
        fake = FakeEnvironment()
        self.addCleanup(fake.close)
        target = plugin.target_from_event(fake.event())
        self.assertIsNotNone(target)
        assert target
        self.assertEqual(target.checkout, fake.checkout.resolve())
        self.assertEqual(str(target.repo_root), PRIMARY)
        self.assertEqual(target.label, "dvic/feature")
        self.assertTrue(target.linked)

    def test_accepts_dotted_worktree_created_variant(self) -> None:
        fake = FakeEnvironment()
        self.addCleanup(fake.close)
        event = fake.event()
        event["event"] = "worktree.created"
        self.assertIsNotNone(plugin.target_from_event(event))

    def test_parses_workspace_context_retry_shape(self) -> None:
        context = {
            "workspace_id": "w-selected",
            "workspace_label": "manual-retry",
            "workspace_cwd": "/tmp/ignored-fallback",
            "worktree": {
                "checkout_path": "/tmp/VerseGuard/manual-retry",
                "repo_root": PRIMARY,
                "is_linked_worktree": True,
            },
        }
        target = plugin.target_from_context(context)
        self.assertIsNotNone(target)
        assert target
        self.assertEqual(str(target.checkout), "/tmp/VerseGuard/manual-retry")
        self.assertEqual(target.label, "manual-retry")
        self.assertTrue(target.linked)


class WorkflowTests(unittest.TestCase):
    def test_filters_non_verseguard_primary_without_calling_tools(self) -> None:
        fake = FakeEnvironment()
        self.addCleanup(fake.close)
        result = fake.run_event("/home/compean/development/SomeOtherRepo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fake.calls(), [])

    def test_creates_no_focus_tab_on_worktree_workspace_after_npm(self) -> None:
        fake = FakeEnvironment()
        self.addCleanup(fake.close)
        result = fake.run_event()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = fake.calls()
        npm_index = next(i for i, call in enumerate(calls) if call["tool"] == "npm")
        create_index = next(
            i for i, call in enumerate(calls)
            if call["tool"] == "herdr" and call["args"][:2] == ["tab", "create"]
        )
        self.assertLess(npm_index, create_index)
        create = calls[create_index]["args"]
        self.assertEqual(create[create.index("--workspace") + 1], "w_1")
        self.assertIn("--no-focus", create)
        self.assertNotIn("--focus", create)
        self.assertFalse(
            any(
                call["args"][:2] == ["workspace", "list"]
                for call in calls
                if call["tool"] == "herdr"
            )
        )

    def test_duplicate_checkout_is_quiet_without_npm_or_relaunch(self) -> None:
        fake = FakeEnvironment(duplicate=True)
        self.addCleanup(fake.close)
        result = fake.run_event()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = fake.calls()
        self.assertFalse(any(call["tool"] == "npm" for call in calls))
        self.assertFalse(any(call["args"][:2] == ["tab", "create"] for call in calls))
        self.assertFalse(any(call["args"][:2] == ["notification", "show"] for call in calls))
        self.assertIn("already exists", result.stderr)

    def test_workspace_focused_resolves_workspace_facts_through_herdr(self) -> None:
        fake = FakeEnvironment()
        self.addCleanup(fake.close)
        result = fake.run_focused()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = fake.calls()
        self.assertIn(
            ["workspace", "get", "w-dashboard"],
            [call["args"] for call in calls if call["tool"] == "herdr"],
        )
        self.assertTrue(any(call["tool"] == "npm" for call in calls))
        create = next(
            call["args"]
            for call in calls
            if call["tool"] == "herdr" and call["args"][:2] == ["tab", "create"]
        )
        self.assertEqual(create[create.index("--workspace") + 1], "w-dashboard")

    def test_focusing_existing_dashboard_is_duplicate_before_npm(self) -> None:
        fake = FakeEnvironment(duplicate=True, checkout_name="dashboard-redesign")
        self.addCleanup(fake.close)
        result = fake.run_focused()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = fake.calls()
        self.assertEqual(calls[0]["args"], ["workspace", "get", "w-dashboard"])
        self.assertFalse(any(call["tool"] == "npm" for call in calls))
        self.assertFalse(
            any(
                call["args"][:2] == ["tab", "create"]
                for call in calls
                if call["tool"] == "herdr"
            )
        )
        self.assertIn("dashboard-redesign", result.stderr)

    def test_launch_uses_branch_label_exact_command_and_fixed_port(self) -> None:
        fake = FakeEnvironment()
        self.addCleanup(fake.close)
        result = fake.run_event()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = fake.calls()
        create = next(call["args"] for call in calls if call["args"][:2] == ["tab", "create"])
        self.assertEqual(create[create.index("--label") + 1], "dvic/feature")
        run = next(call["args"] for call in calls if call["args"][:2] == ["pane", "run"])
        self.assertEqual(run, ["pane", "run", "w_1:p-new", "npx expo start --clear --port 8082"])

    def test_npm_failure_is_visible_and_never_creates_tab(self) -> None:
        fake = FakeEnvironment(npm_exit=9)
        self.addCleanup(fake.close)
        result = fake.run_event()
        self.assertEqual(result.returncode, 1)
        calls = fake.calls()
        self.assertFalse(any(call["args"][:2] == ["tab", "create"] for call in calls if call["tool"] == "herdr"))
        self.assertTrue(any(call["args"][:2] == ["notification", "show"] for call in calls if call["tool"] == "herdr"))
        self.assertIn("npm ci failed", result.stderr)

    def test_retry_creates_tab_on_selected_worktree_workspace(self) -> None:
        fake = FakeEnvironment()
        self.addCleanup(fake.close)
        result = fake.run_retry()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = fake.calls()
        create = next(call["args"] for call in calls if call["args"][:2] == ["tab", "create"])
        self.assertEqual(create[create.index("--workspace") + 1], "w-selected")
        self.assertIn("--no-focus", create)


if __name__ == "__main__":
    unittest.main()
