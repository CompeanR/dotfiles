import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parent / "pi-routing-gate.py"
SPEC = importlib.util.spec_from_file_location("pi_routing_gate", MODULE_PATH)
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class BashClassificationTests(unittest.TestCase):
    def test_read_only_commands(self):
        commands = (
            "ls -la",
            "git status",
            "git -C /x log --oneline",
            "grep -rn foo . | head -5",
            "wc -l file.py && cat file.py",
            "FOO=1 env",
            "env",
            "printenv PATH",
            "git branch --list",
            "git remote -v",
            "git reflog",
            "sort f",
            "uniq f",
            "date",
            "git worktree list",
            "cd /tmp && ls",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertTrue(gate.is_read_only_bash(command))

    def test_read_only_skill_scripts(self):
        commands = (
            "python3 /home/compean/.claude/skills/latest-images/latest-images.py 2",
            'python3 "/home/compean/.claude/skills/latest-images/latest-images.py" 2',
            "python3 $HOME/.claude/skills/latest-images/latest-images.py 2",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertTrue(gate.is_read_only_bash(command))

    def test_python_invocations_that_may_write(self):
        commands = (
            "python3 /tmp/evil.py",
            'python3 -c "import os"',
            "python3 ~/notskills/x.py",
            "python3 /home/compean/.claude/skills/latest-images/latest-images.py 2 > out.txt",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertFalse(gate.is_read_only_bash(command))

    def test_commands_that_may_write(self):
        commands = (
            "rm -rf x",
            "ls > out.txt",
            "echo `rm x`",
            "echo $(date)",
            "find . -name '*.tmp' -delete",
            "git commit -m x",
            "git branch -D foo",
            "git remote add origin url",
            "env touch pwned",
            "env bash -c 'touch pwned'",
            "PATH=/tmp ls",
            "LD_PRELOAD=/tmp/evil.so ls",
            "sort f -o f",
            "uniq input.txt output.txt",
            "xxd file.bin",
            "xxd -r patch.hex file.bin",
            "cat p.hex | xxd -r - out.bin",
            "date -s 2030-01-01",
            "git branch new-branch",
            "git branch -m old new",
            "git remote rename old new",
            "git remote update",
            "git reflog expire --all",
            "git diff --output=out.patch",
            "sed -i s/a/b/ f",
            "pip install x",
            "python3 script.py",
            "cat f | tee g",
            "/tmp/ls",
            "./git status",
            "/usr/bin/find . -delete",
            "sort -oout.txt f",
            "sort --compress-program=/tmp/evil f",
            "rg --pre /tmp/evil needle .",
            "find . -fls out.txt",
            "git diff --ext-diff",
            "git show --textconv HEAD:file",
            "git cat-file --filters --path=x HEAD:x",
            "git grep --open-files-in-pager=/tmp/evil needle",
            12345,
            "",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertFalse(gate.is_read_only_bash(command))


class PathClassificationTests(unittest.TestCase):
    def test_untracked_paths(self):
        self.assertTrue(gate.is_untracked_path("/home/u/.claude/projects/x/memory/f.md"))
        self.assertTrue(gate.is_untracked_path("/tmp/claude-1000/x/scratchpad/a.html"))
        self.assertFalse(gate.is_untracked_path("tmp/x.md"))
        self.assertFalse(gate.is_untracked_path("/home/u/repo/src/main.py"))

    def test_doc_paths(self):
        self.assertTrue(gate.is_doc_path("README.md"))
        self.assertTrue(gate.is_doc_path("notes.TXT"))
        self.assertFalse(gate.is_doc_path("index.html"))
        self.assertFalse(gate.is_doc_path("main.py"))


class FinishWorkTests(unittest.TestCase):
    def test_untracked_write_does_not_count_as_change(self):
        state = gate.initial_state()
        gate.finish_work(
            state,
            {
                "tool_name": "Write",
                "tool_use_id": "temp-write",
                "tool_input": {
                    "file_path": "/tmp/claude-1000/s/scratch/x.html",
                    "content": "x" * 5000,
                },
            },
            True,
        )
        self.assertEqual(state["change_volume"], 0)
        self.assertEqual(state["changed_files"], [])
        self.assertFalse(state["verification_required"])
        self.assertEqual(state["change_epoch"], 0)

    def test_memory_edit_does_not_count_as_change(self):
        state = gate.initial_state()
        gate.finish_work(
            state,
            {
                "tool_name": "Edit",
                "tool_use_id": "memory-edit",
                "tool_input": {
                    "file_path": "/home/u/.claude/projects/x/memory/f.md",
                    "old_string": "old",
                    "new_string": "new",
                },
            },
            True,
        )
        self.assertEqual(state["change_volume"], 0)
        self.assertEqual(state["changed_files"], [])
        self.assertEqual(state["change_epoch"], 0)

    def test_large_code_write_requires_verification(self):
        state = gate.initial_state()
        gate.finish_work(
            state,
            {
                "tool_name": "Write",
                "tool_use_id": "code-write",
                "tool_input": {
                    "file_path": "/home/u/proj/app.py",
                    "content": "x" * 5000,
                },
            },
            True,
        )
        self.assertTrue(state["verification_required"])

    def test_docs_ignore_volume_but_breadth_requires_verification(self):
        state = gate.initial_state()
        paths = (
            "/home/u/proj/README.md",
            "/home/u/proj/docs/one.md",
            "/home/u/proj/docs/two.md",
            "/home/u/proj/docs/three.md",
        )
        for index, path in enumerate(paths):
            gate.finish_work(
                state,
                {
                    "tool_name": "Edit",
                    "tool_use_id": f"doc-edit-{index}",
                    "tool_input": {
                        "file_path": path,
                        "old_string": "",
                        "new_string": "x" * 5000,
                    },
                },
                True,
            )
            self.assertEqual(state["change_volume"], 0)
            if index == 0:
                self.assertEqual(len(state["changed_files"]), 1)
                self.assertFalse(state["verification_required"])
        self.assertEqual(len(state["changed_files"]), 4)
        self.assertTrue(state["verification_required"])

    def test_high_risk_doc_path_is_still_high_risk(self):
        state = gate.initial_state()
        gate.finish_work(
            state,
            {
                "tool_name": "Edit",
                "tool_use_id": "migration-doc",
                "tool_input": {
                    "file_path": "/home/u/proj/docs/migration-notes.md",
                    "old_string": "old",
                    "new_string": "new",
                },
            },
            True,
        )
        self.assertTrue(state["high_risk_change"])

    def test_mixed_paths_are_classified_individually(self):
        state = gate.initial_state()
        gate.finish_work(
            state,
            {
                "tool_name": "MultiEdit",
                "tool_use_id": "mixed-edit",
                "tool_input": {
                    "edits": [
                        {
                            "file_path": "/home/u/proj/README.md",
                            "new_string": "d" * 1000,
                        },
                        {
                            "file_path": "/home/u/proj/app.py",
                            "new_string": "c" * 1000,
                        },
                        {
                            "file_path": "/tmp/claude-1000/scratch.txt",
                            "new_string": "t" * 1000,
                        },
                    ]
                },
            },
            True,
        )
        self.assertEqual(state["change_volume"], 3000)
        self.assertEqual(
            state["changed_files"],
            ["/home/u/proj/README.md", "/home/u/proj/app.py"],
        )

    def test_bash_change_accounting(self):
        state = gate.initial_state()
        gate.finish_work(
            state,
            {
                "tool_name": "Bash",
                "tool_use_id": "read-bash",
                "tool_input": {"command": "ls -la"},
            },
            True,
        )
        self.assertFalse(state["uncertain_change"])
        self.assertEqual(state["change_epoch"], 0)
        gate.finish_work(
            state,
            {
                "tool_name": "Bash",
                "tool_use_id": "write-bash",
                "tool_input": {"command": "rm x"},
            },
            True,
        )
        self.assertTrue(state["uncertain_change"])
        self.assertEqual(state["change_epoch"], 1)

    def test_read_only_bash_preserves_verified_epoch(self):
        state = gate.initial_state()
        state["change_epoch"] = 7
        state["verified_epoch"] = 7
        gate.finish_work(
            state,
            {
                "tool_name": "Bash",
                "tool_use_id": "verified-read",
                "tool_input": {"command": "git status"},
            },
            True,
        )
        self.assertEqual(state["change_epoch"], 7)
        self.assertEqual(state["verified_epoch"], 7)


class GitRepoTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.email", "tests@example.com")
        self.git("config", "user.name", "Pi Routing Gate Tests")
        (self.repo / "app.py").write_text("base\n")
        self.git("add", "app.py")
        self.git("commit", "-qm", "initial")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        subprocess.run(
            ["git", "-C", str(self.repo), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def dispatch_apply(self, state, tool_use_id="apply-call"):
        gate.pre_tool(
            state,
            {
                "cwd": str(self.repo),
                "tool_name": gate.PI_TOOL,
                "tool_use_id": tool_use_id,
                "tool_input": {"role": "apply", "brief": "Make the scoped test change."},
            },
        )
        self.assertIn(tool_use_id, state["pi_inflight"])

    def finish_apply(self, state, tool_use_id="apply-call", succeeded=True):
        gate.finish_pi(
            state,
            {
                "cwd": str(self.repo),
                "tool_name": gate.PI_TOOL,
                "tool_use_id": tool_use_id,
                "tool_response": {"content": "Apply completed."},
            },
            succeeded,
        )


class ApplyDiffTests(GitRepoTestCase):
    def test_diff_stats_include_unstaged_staged_and_untracked_files(self):
        (self.repo / "app.py").write_text("unstaged\n")
        (self.repo / "staged.py").write_text("staged\n")
        self.git("add", "staged.py")
        (self.repo / "untracked.py").write_text("untracked\n")
        files, total = gate.diff_stats({"cwd": str(self.repo)})
        self.assertEqual(set(files), {"app.py", "staged.py", "untracked.py"})
        self.assertEqual(total, sum(files.values()))
        self.assertGreater(total, 0)

    def test_tiny_apply_delta_does_not_require_verification(self):
        state = gate.initial_state()
        self.dispatch_apply(state)
        (self.repo / "app.py").write_text("base\ntiny\n")
        self.finish_apply(state)
        self.assertEqual(state["changed_files"], ["app.py"])
        self.assertLess(state["change_volume"], gate.VERIFY_CHANGE_VOLUME)
        self.assertFalse(state["verification_required"])

    def test_failed_apply_also_uses_measured_delta(self):
        state = gate.initial_state()
        self.dispatch_apply(state)
        (self.repo / "app.py").write_text("base\ntiny\n")
        self.finish_apply(state, succeeded=False)
        self.assertEqual(state["changed_files"], ["app.py"])
        self.assertFalse(state["verification_required"])

    def test_apply_exceeding_file_limit_requires_verification(self):
        state = gate.initial_state()
        self.dispatch_apply(state)
        for index in range(gate.VERIFY_FILE_LIMIT):
            (self.repo / f"file-{index}.py").write_text("x\n")
        self.finish_apply(state)
        self.assertEqual(len(state["changed_files"]), gate.VERIFY_FILE_LIMIT)
        self.assertTrue(state["verification_required"])
        self.assertEqual(state["verification_reason"], "file-count")

    def test_apply_exceeding_volume_requires_verification(self):
        state = gate.initial_state()
        self.dispatch_apply(state)
        (self.repo / "app.py").write_text("x" * gate.VERIFY_CHANGE_VOLUME + "\n")
        self.finish_apply(state)
        self.assertGreaterEqual(state["change_volume"], gate.VERIFY_CHANGE_VOLUME)
        self.assertTrue(state["verification_required"])
        self.assertEqual(state["verification_reason"], "change-volume")

    def test_apply_touching_high_risk_path_requires_verification(self):
        state = gate.initial_state()
        self.dispatch_apply(state)
        (self.repo / "auth.py").write_text("x\n")
        self.finish_apply(state)
        self.assertTrue(state["high_risk_change"])
        self.assertTrue(state["verification_required"])
        self.assertEqual(state["verification_reason"], "high-risk-path")

    def test_preexisting_changes_are_not_attributed_to_apply(self):
        (self.repo / "unrelated.py").write_text("preexisting\n")
        state = gate.initial_state()
        self.dispatch_apply(state)
        (self.repo / "app.py").write_text("base\ntiny\n")
        self.finish_apply(state)
        self.assertEqual(state["changed_files"], ["app.py"])
        self.assertNotIn("unrelated.py", state["changed_files"])
        self.assertFalse(state["verification_required"])

    def test_background_apply_is_uncertain_but_does_not_force_verification(self):
        state = gate.initial_state()
        self.dispatch_apply(state, "background-apply")
        gate.finish_pi(
            state,
            {
                "cwd": str(self.repo),
                "tool_name": gate.PI_TOOL,
                "tool_use_id": "background-apply",
                "tool_response": "Still running after 2s and moved to the background.",
            },
            True,
        )
        self.assertIn("background-apply", state["pi_inflight"])
        self.assertTrue(state["uncertain_change"])
        self.assertFalse(state["verification_required"])

    def test_unmeasured_apply_fails_safe(self):
        state = gate.initial_state()
        with tempfile.TemporaryDirectory() as non_repo:
            gate.pre_tool(
                state,
                {
                    "cwd": non_repo,
                    "tool_name": gate.PI_TOOL,
                    "tool_use_id": "unmeasured",
                    "tool_input": {"role": "apply", "brief": "Make a scoped change."},
                },
            )
            gate.finish_pi(
                state,
                {
                    "cwd": non_repo,
                    "tool_name": gate.PI_TOOL,
                    "tool_use_id": "unmeasured",
                    "tool_response": "Apply failed.",
                },
                False,
            )
        self.assertTrue(state["uncertain_change"])
        self.assertTrue(state["verification_required"])
        self.assertEqual(state["verification_reason"], "apply-unmeasured")


class FinishPiTests(unittest.TestCase):
    def test_background_verify_records_attempt_and_keeps_inflight(self):
        state = gate.initial_state()
        state["change_epoch"] = 4
        state["pi_inflight"]["verify-background"] = {
            "role": "verify",
            "epoch": 4,
            "snapshot": None,
            "started": 0,
        }
        gate.finish_pi(
            state,
            {
                "tool_name": gate.PI_TOOL,
                "tool_use_id": "verify-background",
                "tool_response": {
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                'MCP tool "pi/subagent" is still running after 2s. '
                                "It was moved to the background as task abc and keeps running"
                            ),
                        }
                    ]
                },
            },
            True,
        )
        self.assertIn("verify-background", state["pi_inflight"])
        self.assertGreater(state["pi_inflight"]["verify-background"]["started"], 0)
        self.assertEqual(state["verified_epoch"], -1)
        self.assertEqual(state["verify_failed_epoch"], 4)
        self.assertTrue(state["delegated"])
        self.assertIn("verify", state["delegated_roles"])

    def test_completed_verify_pops_inflight_and_records_verification(self):
        state = gate.initial_state()
        state["change_epoch"] = 4
        state["pi_inflight"]["verify-complete"] = {
            "role": "verify",
            "epoch": 4,
            "snapshot": None,
            "started": 0,
        }
        gate.finish_pi(
            state,
            {
                "tool_name": gate.PI_TOOL,
                "tool_use_id": "verify-complete",
                "tool_response": {"content": "Verification completed successfully"},
            },
            True,
        )
        self.assertNotIn("verify-complete", state["pi_inflight"])
        self.assertEqual(state["verified_epoch"], 4)


class StopEventTests(unittest.TestCase):
    def test_block_reason_names_trigger_and_measurements(self):
        with tempfile.TemporaryDirectory() as cwd:
            subprocess.run(["git", "-C", cwd, "init", "-q"], check=True)
            Path(cwd, "dirty.py").write_text("x\n")
            state = gate.initial_state()
            state["verification_required"] = True
            state["verification_reason"] = "file-count"
            state["changed_files"] = ["a.py", "b.py", "c.py", "d.py"]
            state["change_volume"] = 17
            state["change_epoch"] = 2
            result = gate.stop_event(state, {"cwd": cwd})
        self.assertEqual(result["decision"], "block")
        self.assertIn("file-count", result["reason"])
        self.assertIn("changed files: 4", result["reason"])
        self.assertIn("change volume: 17", result["reason"])

    def test_matching_verified_epoch_clears_requirement(self):
        state = gate.initial_state()
        state["verification_required"] = True
        state["change_epoch"] = 3
        state["verified_epoch"] = 3
        with tempfile.TemporaryDirectory() as cwd:
            result = gate.stop_event(state, {"cwd": cwd})
        self.assertIsNone(result)
        self.assertFalse(state["verification_required"])


if __name__ == "__main__":
    unittest.main()
