#!/usr/bin/env python3
import json
import os
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "claude/scripts/pi-routing-gate.py"
SETTINGS = ROOT / "claude/settings.json"
PI_TOOL = "mcp__pi__subagent"
WORK_LIMIT = 10


class RoutingGateTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.env = os.environ | {"CLAUDE_PI_GATE_STATE_DIR": self.tempdir.name}
        self.session = "session-a"
        self.prompt_id = "prompt-a"
        self.prompt()

    def tearDown(self):
        self.tempdir.cleanup()

    def call(self, action, payload):
        result = subprocess.run(
            [sys.executable, str(GATE), action],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            env=self.env,
            timeout=2,
            check=True,
        )
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout) if result.stdout.strip() else None

    def base(self, **values):
        payload = {
            "session_id": self.session,
            "prompt_id": self.prompt_id,
            "cwd": str(ROOT),
        }
        payload.update(values)
        return payload

    def prompt(self, prompt_id=None):
        if prompt_id is not None:
            self.prompt_id = prompt_id
        return self.call("prompt", self.base(hook_event_name="UserPromptSubmit", prompt="test"))

    def pre(self, name, tool_id, tool_input=None):
        return self.call(
            "pre",
            self.base(
                hook_event_name="PreToolUse",
                tool_name=name,
                tool_use_id=tool_id,
                tool_input=tool_input or {},
            ),
        )

    def finish(self, name, tool_id, tool_input=None, succeeded=True, prompt_id=None):
        payload = self.base(
            hook_event_name="PostToolUse" if succeeded else "PostToolUseFailure",
            tool_name=name,
            tool_use_id=tool_id,
            tool_input=tool_input or {},
        )
        if prompt_id is not None:
            payload["prompt_id"] = prompt_id
        return self.call("post" if succeeded else "failure", payload)

    def complete(self, name, tool_id, tool_input=None):
        self.assertIsNone(self.pre(name, tool_id, tool_input))
        self.assertIsNone(self.finish(name, tool_id, tool_input))

    def stop(self, active=False, background_tasks=None):
        return self.call(
            "stop",
            self.base(
                hook_event_name="Stop",
                stop_hook_active=active,
                last_assistant_message="done",
                background_tasks=background_tasks or [],
            ),
        )

    def complete_reads(self, count, prefix="read"):
        for index in range(count):
            self.complete("Read", f"{prefix}-{index}", {"file_path": f"/tmp/{index}"})

    def pi_input(self, role):
        return {"role": role, "brief": "Self-contained test brief", "cwd": str(ROOT), "timeout_ms": 600000}

    def test_prompt_emits_hidden_routing_context(self):
        output = self.prompt()
        context = output["hookSpecificOutput"]["additionalContext"]
        self.assertEqual(output["hookSpecificOutput"]["hookEventName"], "UserPromptSubmit")
        for value in (PI_TOOL, "explore", "design", "apply", "verify", "ten", "small Edit", "TaskOutput", "self-contained"):
            self.assertIn(value, context)

    def test_blocking_task_output_is_denied_but_nonblocking_status_is_allowed(self):
        blocked = self.pre("TaskOutput", "task-wait", {"task_id": "abc", "block": True, "timeout": 300000})
        default_blocked = self.pre("TaskOutput", "task-default-wait", {"task_id": "abc"})
        self.assertEqual(blocked["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(default_blocked["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("completion notification", blocked["hookSpecificOutput"]["permissionDecisionReason"])
        self.assertIsNone(self.pre("TaskOutput", "task-status", {"task_id": "abc", "block": False}))

    def test_stop_is_allowed_while_pi_task_runs_without_clearing_obligation(self):
        write = {"file_path": "/tmp/a", "content": "x" * 2000}
        self.complete("Write", "large-write-background", write)
        running = [{
            "id": "task-1",
            "type": "mcp",
            "status": "running",
            "description": "pi/subagent",
            "server": "pi",
            "tool": "subagent",
        }]
        self.assertIsNone(self.stop(background_tasks=running))
        self.assertEqual(self.stop(background_tasks=[])["decision"], "block")

    def test_unrelated_or_completed_background_task_does_not_bypass_stop(self):
        write = {"file_path": "/tmp/a", "content": "x" * 2000}
        self.complete("Write", "large-write-other-task", write)
        unrelated = [{
            "id": "task-2",
            "status": "running",
            "description": "build docs about pi/subagent",
            "type": "shell",
        }]
        wrong_server = [{
            "id": "task-3",
            "status": "running",
            "description": "pi/subagent",
            "type": "mcp_task",
            "server": "other",
            "tool": "subagent",
        }]
        completed = [{
            "id": "task-4",
            "status": "completed",
            "description": "pi/subagent",
            "type": "mcp_task",
            "server": "pi",
            "tool": "subagent",
        }]
        self.assertEqual(self.stop(background_tasks=unrelated)["decision"], "block")
        self.assertEqual(self.stop(background_tasks=wrong_server)["decision"], "block")
        self.assertEqual(self.stop(background_tasks=completed)["decision"], "block")

    def test_ten_completed_calls_allowed_and_eleventh_denied(self):
        self.complete_reads(WORK_LIMIT)
        denied = self.pre("Read", "read-11", {"file_path": "/tmp/11"})
        decision = denied["hookSpecificOutput"]
        self.assertEqual(decision["hookEventName"], "PreToolUse")
        self.assertEqual(decision["permissionDecision"], "deny")

    def test_parallel_reservations_enforce_budget_and_failure_releases_one(self):
        for index in range(WORK_LIMIT):
            self.assertIsNone(self.pre("Read", f"parallel-{index}", {"file_path": f"/tmp/{index}"}))
        self.assertEqual(
            self.pre("Read", "parallel-11", {"file_path": "/tmp/11"})["hookSpecificOutput"]["permissionDecision"],
            "deny",
        )
        self.finish("Read", "parallel-0", {"file_path": "/tmp/0"}, succeeded=False)
        self.assertIsNone(self.pre("Read", "parallel-replacement", {"file_path": "/tmp/replacement"}))

    def test_successful_pi_call_unlocks_gate(self):
        self.complete_reads(WORK_LIMIT)
        request = self.pi_input("explore")
        self.assertIsNone(self.pre(PI_TOOL, "pi-explore", request))
        self.finish(PI_TOOL, "pi-explore", request)
        self.assertIsNone(self.pre("Read", "after-delegation", {"file_path": "/tmp/after"}))

    def test_only_valid_failed_pi_call_unlocks_gate(self):
        self.complete_reads(WORK_LIMIT)
        invalid = {"role": "invalid", "brief": "brief"}
        self.pre(PI_TOOL, "pi-invalid", invalid)
        self.finish(PI_TOOL, "pi-invalid", invalid, succeeded=False)
        self.assertEqual(
            self.pre("Read", "still-blocked", {"file_path": "/tmp/blocked"})["hookSpecificOutput"]["permissionDecision"],
            "deny",
        )

        valid = self.pi_input("explore")
        self.pre(PI_TOOL, "pi-failed", valid)
        self.finish(PI_TOOL, "pi-failed", valid, succeeded=False)
        self.assertIsNone(self.pre("Read", "fallback", {"file_path": "/tmp/fallback"}))

    def test_multiple_low_risk_copy_edits_do_not_require_verify(self):
        source = {
            "file_path": "/app/features/card.ts",
            "old_string": "Old message " + "a" * 140,
            "new_string": "New message " + "b" * 140,
        }
        expected = {
            "file_path": "/app/features/__tests__/card.test.ts",
            "old_string": "Old message " + "a" * 140,
            "new_string": "New message " + "b" * 140,
        }
        self.complete("Edit", "copy-source", source)
        self.complete("Edit", "copy-test-1", expected)
        self.complete("Edit", "copy-test-2", expected)
        self.assertIsNone(self.stop())

    def test_verify_started_before_later_change_is_stale(self):
        write = {"file_path": "/tmp/a", "content": "x" * 2000}
        self.complete("Write", "large-write", write)
        verify = self.pi_input("verify")
        self.pre(PI_TOOL, "verify-old", verify)
        self.complete("Bash", "bash-after-verify-start", {"command": "true"})
        self.finish(PI_TOOL, "verify-old", verify)
        self.assertEqual(self.stop()["decision"], "block")

        self.pre(PI_TOOL, "verify-current", verify)
        self.finish(PI_TOOL, "verify-current", verify)
        self.assertIsNone(self.stop())

    def test_large_deletion_requires_verify(self):
        deletion = {"file_path": "/tmp/a", "old_string": "x" * 2000, "new_string": ""}
        self.complete("Edit", "large-delete", deletion)
        self.assertEqual(self.stop()["decision"], "block")

    def test_one_small_edit_bypasses_exhausted_budget_without_forcing_verify(self):
        self.complete_reads(WORK_LIMIT)
        small = {"file_path": "/tmp/b", "old_string": "a" * 125, "new_string": "b" * 125}
        self.complete("Edit", "small-bypass", small)
        self.assertIsNone(self.stop())
        self.assertEqual(
            self.pre("Edit", "second-small", small)["hookSpecificOutput"]["permissionDecision"],
            "deny",
        )

    def test_large_edit_does_not_bypass_exhausted_budget(self):
        self.complete_reads(WORK_LIMIT)
        large = {"file_path": "/tmp/b", "old_string": "a" * 125, "new_string": "b" * 126}
        self.assertEqual(
            self.pre("Edit", "large-after-budget", large)["hookSpecificOutput"]["permissionDecision"],
            "deny",
        )

    def test_single_small_edit_does_not_force_verify(self):
        edit = {"file_path": "/tmp/a", "old_string": "a", "new_string": "b"}
        self.complete("Edit", "small-edit", edit)
        self.assertIsNone(self.stop())

    def test_bash_is_potential_change_at_work_threshold(self):
        self.complete("Bash", "bash-1", {"command": "true"})
        self.complete_reads(WORK_LIMIT - 1, prefix="after-bash")
        self.assertEqual(self.stop()["decision"], "block")

    def test_failed_bash_can_still_create_verification_obligation(self):
        command = {"command": "touch /tmp/example; false"}
        self.pre("Bash", "bash-failure", command)
        self.finish("Bash", "bash-failure", command, succeeded=False)
        self.complete_reads(WORK_LIMIT, prefix="after-failed-bash")
        self.assertEqual(self.stop()["decision"], "block")

    def test_moderate_edit_volume_does_not_require_verify(self):
        edit = {"file_path": "/tmp/a", "old_string": "a" * 300, "new_string": "b" * 300}
        self.complete("Edit", "replacement-600", edit)
        self.assertIsNone(self.stop())

    def test_large_submitted_edit_volume_requires_verify(self):
        edit = {"file_path": "/tmp/a", "old_string": "a" * 1000, "new_string": "b" * 1000}
        self.complete("Edit", "replacement-2000", edit)
        self.assertEqual(self.stop()["decision"], "block")

    def test_failed_explicit_mutation_can_still_require_verify(self):
        write = {"file_path": "/tmp/a", "content": "x" * 2000}
        self.pre("Write", "failed-write", write)
        self.finish("Write", "failed-write", write, succeeded=False)
        self.assertEqual(self.stop()["decision"], "block")

    def test_notebook_deletions_without_submitted_text_do_not_require_verify(self):
        deletion = {"notebook_path": "/tmp/a.ipynb", "cell_id": "1", "edit_mode": "delete"}
        self.complete("NotebookEdit", "delete-cell-1", deletion)
        self.complete("NotebookEdit", "delete-cell-2", deletion)
        self.assertIsNone(self.stop())

    def test_multiedit_counts_submitted_text_not_json_metadata(self):
        small = {"edits": [{"file_path": "/tmp/" + "x" * 600, "old_string": "a", "new_string": "b"}]}
        self.complete("MultiEdit", "small-multiedit", small)
        self.assertIsNone(self.stop())

        self.prompt("multiedit-large")
        large = {"edits": [{"old_string": "a" * 1000, "new_string": "b" * 1000}]}
        self.complete("MultiEdit", "large-multiedit", large)
        self.assertEqual(self.stop()["decision"], "block")

    def test_small_high_risk_path_change_requires_verify(self):
        edit = {"file_path": "/app/auth/session.ts", "old_string": "false", "new_string": "true"}
        self.complete("Edit", "auth-edit", edit)
        self.assertEqual(self.stop()["decision"], "block")

    def test_changes_across_four_files_require_verify(self):
        for index in range(4):
            edit = {"file_path": f"/app/feature-{index}.ts", "old_string": "a", "new_string": "b"}
            self.complete("Edit", f"file-{index}", edit)
        self.assertEqual(self.stop()["decision"], "block")

    def test_path_aliases_do_not_inflate_distinct_file_count(self):
        aliases = ("/app/a.ts", "/app/./a.ts", "/app/x/../a.ts", "\\app\\a.ts")
        for index, path in enumerate(aliases):
            edit = {"file_path": path, "old_string": "a", "new_string": "b"}
            self.complete("Edit", f"alias-{index}", edit)
        self.assertIsNone(self.stop())

    def test_high_risk_path_matching_covers_compound_names_and_manifests(self):
        gate = runpy.run_path(str(GATE))
        is_high_risk = gate["is_high_risk_path"]
        risky = (
            "/app/auth-service.ts",
            "/app/security_utils.py",
            "/app/permission-check.ts",
            "/app/2026-user-migration.sql",
            "/app/deploy-prod.yml",
            "/app/infra.config.ts",
            "/app/OAuthService.ts",
            "/app/APIAuthConfig.ts",
            "/app/SSLSecurityPolicy.ts",
            "/repo/Cargo.toml",
            "/repo/go.mod",
            "/repo/composer.json",
            "/repo/poetry.lock",
            "/repo/uv.lock",
            "/repo/Pipfile.lock",
            "/repo/bun.lockb",
            "/repo/requirements-dev.txt",
            "/repo/.github/workflows/release.yml",
            "/repo/.env.production",
        )
        for path in risky:
            with self.subTest(path=path):
                self.assertTrue(is_high_risk(path))
        for path in ("/app/author/profile.ts", "/app/environment/view.ts", "/app/schematic.ts"):
            with self.subTest(path=path):
                self.assertFalse(is_high_risk(path))

    def test_prior_state_version_preserves_common_safety_state(self):
        gate = runpy.run_path(str(GATE))
        migrated = gate["normalized_state"]({
            "version": 2,
            "prompt_id": "old-prompt",
            "work_completed": 10,
            "change_epoch": 4,
            "verification_required": True,
            "verified_epoch": 3,
        })
        self.assertEqual(migrated["version"], 3)
        self.assertEqual(migrated["work_completed"], 10)
        self.assertEqual(migrated["change_epoch"], 4)
        self.assertTrue(migrated["verification_required"])

    def test_ask_user_question_response_resets_work_budget(self):
        self.complete_reads(WORK_LIMIT)
        self.assertEqual(
            self.pre("Read", "blocked-before-answer", {"file_path": "/tmp/blocked"})["hookSpecificOutput"]["permissionDecision"],
            "deny",
        )
        question = {"questions": [{"question": "Continue?"}]}
        self.finish("AskUserQuestion", "question-1", question)
        self.assertIsNone(self.pre("Read", "after-answer", {"file_path": "/tmp/after"}))

    def test_ask_user_question_reset_preserves_verification_obligation(self):
        write = {"file_path": "/tmp/a", "content": "x" * 2000}
        self.complete("Write", "large-write-before-question", write)
        question = {"questions": [{"question": "Continue?"}]}
        self.finish("AskUserQuestion", "question-1", question)
        self.assertEqual(self.stop()["decision"], "block")

    def test_successful_and_failed_apply_both_require_verify(self):
        apply_request = self.pi_input("apply")
        self.pre(PI_TOOL, "apply-success", apply_request)
        self.finish(PI_TOOL, "apply-success", apply_request)
        self.assertEqual(self.stop()["decision"], "block")

        verify = self.pi_input("verify")
        self.pre(PI_TOOL, "verify-successful-apply", verify)
        self.finish(PI_TOOL, "verify-successful-apply", verify)
        self.assertIsNone(self.stop())

        self.prompt("prompt-c")
        self.pre(PI_TOOL, "apply-failure", apply_request)
        self.finish(PI_TOOL, "apply-failure", apply_request, succeeded=False)
        self.assertEqual(self.stop()["decision"], "block")

    def test_current_epoch_verify_failure_fails_open_but_later_change_invalidates_it(self):
        write = {"file_path": "/tmp/a", "content": "x" * 2000}
        self.complete("Write", "large-write", write)
        verify = self.pi_input("verify")
        self.pre(PI_TOOL, "verify-failure", verify)
        self.finish(PI_TOOL, "verify-failure", verify, succeeded=False)
        self.assertIsNone(self.stop())

        edit = {"file_path": "/tmp/a", "old_string": "a", "new_string": "b"}
        self.complete("Edit", "later-edit", edit)
        self.assertEqual(self.stop()["decision"], "block")

    def test_duplicate_events_and_prompt_retries_are_idempotent(self):
        edit = {"file_path": "/tmp/a", "old_string": "a", "new_string": "b"}
        self.complete("Edit", "edit-once", edit)
        self.finish("Edit", "edit-once", edit)
        self.assertIsNone(self.stop())

        gate = runpy.run_path(str(GATE))
        state = gate["initial_state"]()
        for index in range(600):
            gate["mark_processed"](state, f"terminal-{index}")
        self.assertEqual(len(state["processed_tools"]), 600)
        self.assertIn("terminal-0", state["processed_tools"])

        self.complete_reads(WORK_LIMIT - 1)
        self.prompt(self.prompt_id)
        self.assertEqual(
            self.pre("Read", "retry-must-not-reset", {"file_path": "/tmp/retry"})["hookSpecificOutput"]["permissionDecision"],
            "deny",
        )

    def test_new_prompt_preserves_unresolved_verification_and_ignores_old_post(self):
        write = {"file_path": "/tmp/a", "content": "x" * 2000}
        self.complete("Write", "large-write", write)
        old_prompt = self.prompt_id
        self.prompt("prompt-new")
        self.finish("Edit", "delayed-old", {"old_string": "a", "new_string": "b"}, prompt_id=old_prompt)
        self.assertEqual(self.stop()["decision"], "block")

    def test_legacy_payloads_without_prompt_id_reset_on_each_prompt(self):
        self.call("cleanup", {"session_id": self.session, "hook_event_name": "SessionEnd", "reason": "other"})
        legacy = {"session_id": self.session, "cwd": str(ROOT)}
        self.call("prompt", legacy | {"hook_event_name": "UserPromptSubmit", "prompt": "first"})
        for index in range(WORK_LIMIT):
            payload = legacy | {
                "hook_event_name": "PreToolUse",
                "tool_name": "Read",
                "tool_use_id": f"legacy-{index}",
                "tool_input": {"file_path": f"/tmp/{index}"},
            }
            self.assertIsNone(self.call("pre", payload))
            self.assertIsNone(self.call("post", payload | {"hook_event_name": "PostToolUse"}))
        self.assertEqual(
            self.call("pre", legacy | {
                "hook_event_name": "PreToolUse",
                "tool_name": "Read",
                "tool_use_id": "legacy-blocked",
                "tool_input": {"file_path": "/tmp/blocked"},
            })["hookSpecificOutput"]["permissionDecision"],
            "deny",
        )
        self.call("prompt", legacy | {"hook_event_name": "UserPromptSubmit", "prompt": "second"})
        self.assertIsNone(self.call("pre", legacy | {
            "hook_event_name": "PreToolUse",
            "tool_name": "Read",
            "tool_use_id": "legacy-new-turn",
            "tool_input": {"file_path": "/tmp/new"},
        }))

    def test_session_end_cleanup_and_malformed_input_fail_open(self):
        write = {"file_path": "/tmp/a", "content": "x" * 2000}
        self.complete("Write", "large-write", write)
        self.call("cleanup", {"session_id": self.session, "hook_event_name": "SessionEnd", "reason": "other"})
        self.assertIsNone(self.stop())

        result = subprocess.run(
            [sys.executable, str(GATE), "pre"],
            input="not json",
            text=True,
            capture_output=True,
            env=self.env,
            timeout=2,
            check=True,
        )
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_settings_register_gate_without_disturbing_branch_guard(self):
        settings = json.loads(SETTINGS.read_text())
        hooks = settings["hooks"]
        for event in ("PreToolUse", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop", "SessionEnd"):
            self.assertIn(event, hooks)
        self.assertFalse("matcher" in hooks["UserPromptSubmit"][0])
        self.assertFalse("matcher" in hooks["Stop"][0])
        self.assertEqual(hooks["PreToolUse"][0]["hooks"][0]["command"], "$HOME/dotfiles/claude/scripts/guard-default-branch.sh")
        gate_pre_matcher = hooks["PreToolUse"][1]["matcher"]
        self.assertIn("TaskOutput", gate_pre_matcher)
        post_matcher = hooks["PostToolUse"][0]["matcher"]
        self.assertIn("AskUserQuestion", post_matcher)
        serialized = json.dumps(settings)
        self.assertIn("pi-routing-gate.py", serialized)
        self.assertNotIn("pi-routing-reminder.sh", serialized)


if __name__ == "__main__":
    unittest.main(verbosity=2)
