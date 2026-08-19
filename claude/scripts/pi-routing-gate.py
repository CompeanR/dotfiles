#!/usr/bin/env python3
import fcntl
import hashlib
import json
import os
import posixpath
import re
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

PI_TOOL = "mcp__pi__subagent"
TASK_OUTPUT_TOOL = "TaskOutput"
ROLES = {"explore", "design", "apply", "verify"}
WORK_TOOLS = {
    "Read",
    "Glob",
    "Grep",
    "WebFetch",
    "WebSearch",
    "Bash",
    "Edit",
    "Write",
    "NotebookEdit",
    "MultiEdit",
}
EXPLICIT_MUTATION_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
DOC_EXTENSIONS = {".md", ".markdown", ".rst", ".txt", ".adoc"}
READ_ONLY_BASH_COMMANDS = {
    "ls",
    "cat",
    "head",
    "tail",
    "wc",
    "grep",
    "rg",
    "fd",
    "find",
    "file",
    "stat",
    "du",
    "df",
    "pwd",
    "which",
    "whereis",
    "type",
    "echo",
    "printf",
    "env",
    "printenv",
    "date",
    "uname",
    "whoami",
    "id",
    "ps",
    "tr",
    "cut",
    "sort",
    "uniq",
    "column",
    "diff",
    "cmp",
    "md5sum",
    "sha256sum",
    "basename",
    "dirname",
    "realpath",
    "readlink",
    "test",
    "true",
    "jq",
    "strings",
    "cd",
    "git",
    "python3",
}
READ_ONLY_GIT_SUBCOMMANDS = {
    "status",
    "log",
    "diff",
    "show",
    "rev-parse",
    "branch",
    "ls-files",
    "ls-tree",
    "blame",
    "shortlog",
    "describe",
    "remote",
    "grep",
    "cat-file",
    "rev-list",
    "reflog",
    "worktree",
}
WORK_LIMIT = 10
SMALL_EDIT_LIMIT = 250
STOP_BLOCK_LIMIT = 2
PI_INFLIGHT_TTL = 3600
VERIFY_CHANGE_VOLUME = 2000
VERIFY_FILE_LIMIT = 4
HIGH_RISK_SEGMENTS = {
    "auth",
    "authentication",
    "authorization",
    "security",
    "crypto",
    "permission",
    "permissions",
    "migration",
    "migrations",
    "schema",
    "schemas",
    "infra",
    "deploy",
    "deployment",
}
HIGH_RISK_FILES = {
    "package.json",
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "bun.lock",
    "bun.lockb",
    "deno.lock",
    "cargo.toml",
    "cargo.lock",
    "go.mod",
    "go.sum",
    "composer.json",
    "composer.lock",
    "pyproject.toml",
    "poetry.lock",
    "uv.lock",
    "pipfile",
    "pipfile.lock",
    "requirements.txt",
    "gemfile",
    "gemfile.lock",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "gradle.lockfile",
    "dockerfile",
}

REMINDER = (
    "PI ROUTING GATE: Use mcp__pi__subagent for independently scoped substantial work. "
    "Route investigation to explore, implementation-ready planning to design, scoped "
    "implementation to apply, and independent validation to verify. Use only roles the "
    "task benefits from; handle conversation, quick answers, obvious local edits, and "
    "tightly coupled work directly. After ten solo work-tool calls, further substantial "
    "work is blocked until a valid Pi delegation completes or fails; one small Edit is "
    "exempt. High-risk, broad, or externally applied changes cannot finish until a "
    "verify run completes. Never block on a background task with TaskOutput; continue "
    "safe orchestration or end the turn and rely on its completion notification. Workers "
    "inherit no context, so provide a self-contained brief, correct cwd, explicit "
    "constraints, and timeout_ms >= 600000."
)


def initial_state():
    return {
        "version": 5,
        "prompt_id": "",
        "legacy_prompt_seq": 0,
        "work_completed": 0,
        "work_reserved": {},
        "processed_tools": [],
        "pi_inflight": {},
        "delegated": False,
        "delegation_failed": False,
        "delegated_roles": [],
        "small_edit_bypass_used": False,
        "change_volume": 0,
        "changed_files": [],
        "high_risk_change": False,
        "uncertain_change": False,
        "change_epoch": 0,
        "verification_required": False,
        "verified_epoch": -1,
        "verify_failed_epoch": -1,
        "verified_snapshot": "",
        "verify_failed_snapshot": "",
        "stop_blocks": 0,
        "stop_block_epoch": -1,
    }


def normalized_state(value):
    state = initial_state()
    if isinstance(value, dict) and value.get("version") in {1, 2, 3, 4, 5}:
        for key in state:
            if key == "version":
                continue
            if key in value and isinstance(value[key], type(state[key])):
                state[key] = value[key]
    state["stop_blocks"] = max(0, state["stop_blocks"])
    return state


def fresh_pi_inflight(state):
    now = time.time()
    for call in state["pi_inflight"].values():
        started = call.get("started") if isinstance(call, dict) else None
        if isinstance(started, (int, float)) and now - started < PI_INFLIGHT_TTL:
            return True
    return False


def state_root():
    configured = os.environ.get("CLAUDE_PI_GATE_STATE_DIR")
    root = Path(configured) if configured else Path(tempfile.gettempdir()) / f"claude-pi-routing-{os.getuid()}"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    return root


def session_key(payload):
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return None
    return hashlib.sha256(session_id.encode()).hexdigest()


def git_output(cwd, *args):
    try:
        result = subprocess.run(
            ["git", "-C", cwd, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=1.5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 else None


def worktree_snapshot(payload):
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        return None

    root_output = git_output(cwd, "rev-parse", "--show-toplevel")
    if root_output is None:
        return None
    root = os.fsdecode(root_output.rstrip(b"\n"))
    status = git_output(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    if status is None:
        return None
    if not status:
        return "clean"

    unstaged = git_output(root, "diff", "--raw", "--full-index")
    unstaged_paths = git_output(root, "diff", "--name-only", "-z")
    staged = git_output(root, "diff", "--cached", "--raw", "--full-index")
    untracked = git_output(root, "ls-files", "--others", "--exclude-standard", "-z")
    if unstaged is None or unstaged_paths is None or staged is None or untracked is None:
        return None

    digest = hashlib.sha256()
    for label, value in ((b"status", status), (b"unstaged", unstaged), (b"staged", staged)):
        digest.update(label + b"\0" + value + b"\0")

    root_bytes = os.fsencode(root)
    snapshot_paths = (
        (b"worktree", relative) for relative in filter(None, unstaged_paths.split(b"\0"))
    )
    untracked_paths = (
        (b"untracked", relative) for relative in filter(None, untracked.split(b"\0"))
    )
    for label, relative in (*snapshot_paths, *untracked_paths):
        digest.update(label + b"\0" + relative + b"\0")
        path = os.path.join(root_bytes, relative)
        try:
            if os.path.islink(path):
                digest.update(b"symlink\0" + os.readlink(path) + b"\0")
                continue
            with open(path, "rb") as stream:
                while chunk := stream.read(1024 * 1024):
                    digest.update(chunk)
        except OSError:
            digest.update(b"unavailable")
        digest.update(b"\0")
    return f"dirty:{digest.hexdigest()}"


@contextmanager
def locked_session(payload):
    key = session_key(payload)
    if key is None:
        yield None, None
        return

    root = state_root()
    state_path = root / f"{key}.json"
    lock_path = root / f"{key}.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(lock_fd, "r+") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
            try:
                state = normalized_state(json.loads(state_path.read_text()))
            except (FileNotFoundError, json.JSONDecodeError, OSError):
                state = initial_state()
            yield state, state_path
        finally:
            fcntl.flock(lock_file, fcntl.LOCK_UN)


def save_state(path, state):
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(state, stream, separators=(",", ":"), sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def reset_work_phase(state):
    state.update(
        {
            "work_completed": 0,
            "work_reserved": {},
            "delegated": False,
            "delegation_failed": False,
            "delegated_roles": [],
            "small_edit_bypass_used": False,
        }
    )


def start_prompt(state, prompt_id):
    if not isinstance(prompt_id, str) or not prompt_id or state["prompt_id"] == prompt_id:
        return

    obligation_satisfied = state["verification_required"] and (
        state["verified_epoch"] == state["change_epoch"]
        or state["verify_failed_epoch"] == state["change_epoch"]
    )
    if obligation_satisfied:
        state["verification_required"] = False

    state.update(
        {
            "prompt_id": prompt_id,
            "processed_tools": [],
            "pi_inflight": {},
            "change_volume": 0,
            "changed_files": [],
            "high_risk_change": False,
            "uncertain_change": False,
            "stop_blocks": 0,
            "stop_block_epoch": -1,
        }
    )
    reset_work_phase(state)


def current_prompt(state, payload):
    prompt_id = payload.get("prompt_id")
    if not isinstance(prompt_id, str) or not prompt_id:
        return True
    if not state["prompt_id"]:
        start_prompt(state, prompt_id)
    return state["prompt_id"] == prompt_id


def valid_pi_input(tool_input):
    return (
        isinstance(tool_input, dict)
        and tool_input.get("role") in ROLES
        and isinstance(tool_input.get("brief"), str)
        and bool(tool_input["brief"].strip())
    )


def submitted_edit_text(value):
    if isinstance(value, list):
        return sum(submitted_edit_text(item) for item in value)
    if not isinstance(value, dict):
        return 0
    text_fields = ("old_string", "new_string", "content", "new_source", "cell_source")
    size = 0
    for name in text_fields:
        field = value.get(name)
        if isinstance(field, str):
            size += len(field)
    return size + submitted_edit_text(value.get("edits", []))


def change_volume(tool_name, tool_input):
    if not isinstance(tool_input, dict):
        return 0
    if tool_name in EXPLICIT_MUTATION_TOOLS:
        return submitted_edit_text(tool_input)
    return 0


def submitted_paths(value):
    if isinstance(value, list):
        paths = []
        for item in value:
            paths.extend(submitted_paths(item))
        return paths
    if not isinstance(value, dict):
        return []
    paths = []
    for name in ("file_path", "notebook_path"):
        path = value.get(name)
        if isinstance(path, str) and path:
            paths.append(path)
    paths.extend(submitted_paths(value.get("edits", [])))
    return paths


def canonical_path(path):
    return posixpath.normpath(path.replace("\\", "/"))


def is_high_risk_path(path):
    normalized = canonical_path(path)
    lowered = normalized.lower()
    filename = lowered.rsplit("/", 1)[-1]
    tokens = set()
    for part in normalized.split("/"):
        camel_split = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", part)
        camel_split = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", camel_split)
        tokens.update(token for token in re.split(r"[^a-z0-9]+", camel_split.lower()) if token)
    return (
        bool(tokens & HIGH_RISK_SEGMENTS)
        or filename in HIGH_RISK_FILES
        or filename.endswith((".lock", ".lockb"))
        or (filename.startswith("requirements") and filename.endswith(".txt"))
        or "/.github/workflows/" in f"/{lowered.strip('/')}"
        or filename.startswith(".env")
    )


def is_memory_path(path):
    parts = canonical_path(path).split("/")
    for i, part in enumerate(parts):
        if (
            part == ".claude"
            and i + 3 < len(parts)
            and parts[i + 1] == "projects"
            and parts[i + 3] == "memory"
        ):
            return True
    return False


def is_untracked_path(path):
    if is_memory_path(path):
        return True
    if not os.path.isabs(path):
        return False
    normalized = canonical_path(os.path.abspath(path))
    temp_root = canonical_path(os.path.abspath(tempfile.gettempdir())).rstrip("/")
    return normalized.startswith(f"{temp_root}/") or normalized.startswith("/tmp/")


def is_doc_path(path):
    return posixpath.splitext(canonical_path(path).lower())[1] in DOC_EXTENSIONS


def is_read_only_bash(command):
    if not isinstance(command, str) or not command.strip():
        return False
    forbidden = (">", "`", "$(", "<(", ">>", "&>", "2>", "|&", "rm ", "sudo ", "eval ", "exec ")
    if any(value in command for value in forbidden):
        return False

    assignment_pattern = r"([A-Za-z_][A-Za-z0-9_]*)=.*"
    disallowed_assignment_names = {"PATH", "IFS", "ENV", "BASH_ENV", "SHELL", "CDPATH", "PS4", "FPATH"}
    disallowed_assignment_prefixes = (
        "LD_",
        "DYLD_",
        "PYTHON",
        "GIT_",
        "PERL5",
        "RUBY",
        "NODE_",
        "MALLOC_",
        "GCONV_",
    )
    branch_options = {
        "-a",
        "-r",
        "-v",
        "-vv",
        "--all",
        "--remotes",
        "--verbose",
        "--list",
        "--show-current",
        "--merged",
        "--no-merged",
        "--contains",
    }
    segments = re.split(r"&&|\|\||;|\||\n", command)
    for segment in segments:
        segment = segment.strip()
        if not segment:
            return False
        tokens = segment.split()
        while tokens:
            assignment = re.fullmatch(assignment_pattern, tokens[0])
            if assignment is None:
                break
            name = assignment.group(1)
            if name in disallowed_assignment_names or name.startswith(disallowed_assignment_prefixes):
                return False
            tokens.pop(0)
        if not tokens:
            return False
        if "/" in tokens[0]:
            return False
        head = tokens[0]
        if head not in READ_ONLY_BASH_COMMANDS:
            return False
        writer_flags = (
            "--output",
            "--output-file",
            "--compress-program",
            "--ext-diff",
            "--textconv",
            "--filters",
            "--open-files-in-pager",
            "--pre",
            "-fls",
            "-fprint",
            "-fprint0",
        )
        writer_prefixes = (
            "--output=",
            "--output-file=",
            "--compress-program=",
            "--open-files-in-pager=",
            "--pre=",
            "--ext-diff=",
            "--textconv=",
            "--filters=",
            "-fls=",
        )
        if any(token in writer_flags or token.startswith(writer_prefixes) for token in tokens[1:]):
            return False
        if head == "env" and any(re.fullmatch(assignment_pattern, token) is None for token in tokens[1:]):
            return False
        if head == "find" and any(
            value in segment
            for value in ("-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint")
        ):
            return False
        if head == "sort" and any(token.startswith("-o") or token.startswith("--output") for token in tokens[1:]):
            return False
        if head == "uniq" and sum(not token.startswith("-") for token in tokens[1:]) > 1:
            return False
        if head == "date" and any(
            token in {"-s", "--set"} or token.startswith("--set=") for token in tokens[1:]
        ):
            return False
        if head == "git":
            if any(token == "-o" or token.startswith("--output") for token in tokens[1:]):
                return False
            index = 1
            while index < len(tokens) and tokens[index].startswith("-"):
                if tokens[index] == "-C":
                    index += 2
                else:
                    index += 1
            if index >= len(tokens) or tokens[index] not in READ_ONLY_GIT_SUBCOMMANDS:
                return False
            subcommand = tokens[index]
            remainder = tokens[index + 1 :]
            if subcommand == "branch" and any(token not in branch_options for token in remainder):
                return False
            if subcommand == "remote" and not (
                not remainder
                or all(token in {"-v", "--verbose"} for token in remainder)
                or remainder[0] in {"show", "get-url"}
            ):
                return False
            if subcommand == "reflog" and any(token in {"expire", "delete", "drop"} for token in remainder):
                return False
            if subcommand == "worktree" and (not remainder or remainder[0] != "list"):
                return False
        if head == "python3" and (len(tokens) != 2 or tokens[1] not in {"--version", "-V"}):
            return False
    return True


def mark_processed(state, tool_use_id):
    if tool_use_id:
        state["processed_tools"].append(tool_use_id)


def recompute_verification(state):
    if (
        state["change_volume"] >= VERIFY_CHANGE_VOLUME
        or len(state["changed_files"]) >= VERIFY_FILE_LIMIT
        or state["high_risk_change"]
    ):
        state["verification_required"] = True
    if state["uncertain_change"] and state["work_completed"] >= WORK_LIMIT:
        state["verification_required"] = True


def pre_tool(state, payload):
    if not current_prompt(state, payload):
        return None

    tool_name = payload.get("tool_name")
    tool_input = payload.get("tool_input", {})
    tool_use_id = payload.get("tool_use_id")

    if tool_name == TASK_OUTPUT_TOOL:
        blocking = not isinstance(tool_input, dict) or tool_input.get("block", True) is not False
        if blocking:
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        "Do not block the orchestrator on a background task. The completion "
                        "notification will arrive automatically. Continue safe independent "
                        "orchestration, use TaskOutput with block=false for a status snapshot, "
                        "or end the turn so the user can keep conversing."
                    ),
                }
            }
        return None

    if tool_name == PI_TOOL:
        if tool_use_id and valid_pi_input(tool_input):
            state["pi_inflight"][tool_use_id] = {
                "role": tool_input["role"],
                "epoch": state["change_epoch"],
                "snapshot": worktree_snapshot(payload),
                "started": time.time(),
            }
        return None

    if tool_name not in WORK_TOOLS:
        return None

    used = state["work_completed"] + len(state["work_reserved"])
    unlocked = state["delegated"] or state["delegation_failed"]
    if not unlocked and used >= WORK_LIMIT:
        small_edit = (
            tool_name == "Edit"
            and change_volume(tool_name, tool_input) <= SMALL_EDIT_LIMIT
            and not state["small_edit_bypass_used"]
        )
        if small_edit:
            state["small_edit_bypass_used"] = True
        else:
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        "Pi routing gate reached after ten solo work calls. Before continuing "
                        "substantial investigation or implementation, call mcp__pi__subagent "
                        "with the appropriate explore, design, apply, or verify role and a "
                        "self-contained brief. One small direct Edit is allowed, but larger or "
                        "additional work requires the delegation decision."
                    ),
                }
            }

    if tool_use_id and tool_use_id not in state["processed_tools"]:
        state["work_reserved"][tool_use_id] = tool_name
    return None


def finish_work(state, payload, succeeded):
    tool_name = payload.get("tool_name")
    tool_use_id = payload.get("tool_use_id")
    if tool_name not in WORK_TOOLS:
        return
    if tool_use_id and tool_use_id in state["processed_tools"]:
        return

    if tool_use_id:
        state["work_reserved"].pop(tool_use_id, None)
    if succeeded:
        state["work_completed"] += 1
    if tool_name in EXPLICIT_MUTATION_TOOLS:
        tool_input = payload.get("tool_input", {})
        paths = submitted_paths(tool_input)
        if not (paths and all(is_untracked_path(p) for p in paths)):
            tracked_paths = [path for path in paths if not is_untracked_path(path)]
            if not tracked_paths or any(not is_doc_path(path) for path in tracked_paths):
                state["change_volume"] += change_volume(tool_name, tool_input)
            for path in tracked_paths:
                canonical = canonical_path(path)
                if canonical not in state["changed_files"]:
                    state["changed_files"].append(canonical)
                if is_high_risk_path(canonical):
                    state["high_risk_change"] = True
            state["change_epoch"] += 1
            recompute_verification(state)
    elif tool_name == "Bash":
        tool_input = payload.get("tool_input", {})
        command = tool_input.get("command") if isinstance(tool_input, dict) else None
        if not is_read_only_bash(command):
            state["uncertain_change"] = True
            state["change_epoch"] += 1
            recompute_verification(state)
    elif succeeded:
        recompute_verification(state)
    mark_processed(state, tool_use_id)


def tool_response_text(payload):
    response = payload.get("tool_response")
    if isinstance(response, str):
        return response
    if not isinstance(response, dict):
        return ""
    content = response.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return "\n".join(
        block["text"]
        for block in content
        if isinstance(block, dict) and isinstance(block.get("text"), str)
    )


def is_background_transition(payload):
    text = tool_response_text(payload)
    return bool(re.search(r"moved to (the )?background", text, re.IGNORECASE)) or "still running after" in text.lower()


def finish_pi(state, payload, succeeded):
    if payload.get("tool_name") != PI_TOOL:
        return
    tool_use_id = payload.get("tool_use_id")
    if tool_use_id and tool_use_id in state["processed_tools"]:
        return

    call = state["pi_inflight"].get(tool_use_id) if tool_use_id else None
    if call is None:
        return

    role = call["role"]
    captured_epoch = call["epoch"]
    if succeeded and is_background_transition(payload):
        state["delegated"] = True
        if role not in state["delegated_roles"]:
            state["delegated_roles"].append(role)
        call["started"] = time.time()
        if role == "apply":
            state["uncertain_change"] = True
            state["change_epoch"] += 1
            state["verification_required"] = True
        elif role == "verify":
            state["verify_failed_epoch"] = max(state["verify_failed_epoch"], captured_epoch)
        mark_processed(state, tool_use_id)
        return

    state["pi_inflight"].pop(tool_use_id, None)
    captured_snapshot = call.get("snapshot")
    current_snapshot = worktree_snapshot(payload) if role == "verify" else None
    unchanged_snapshot = current_snapshot is not None and current_snapshot == captured_snapshot
    if succeeded:
        state["delegated"] = True
        if role not in state["delegated_roles"]:
            state["delegated_roles"].append(role)
        if role == "apply":
            state["uncertain_change"] = True
            state["change_epoch"] += 1
            state["verification_required"] = True
        elif role == "verify":
            state["verified_epoch"] = max(state["verified_epoch"], captured_epoch)
            if unchanged_snapshot:
                state["verified_snapshot"] = current_snapshot
                state["verified_epoch"] = state["change_epoch"]
    else:
        state["delegation_failed"] = True
        if role == "apply":
            state["uncertain_change"] = True
            state["change_epoch"] += 1
            state["verification_required"] = True
        elif role == "verify":
            state["verify_failed_epoch"] = max(state["verify_failed_epoch"], captured_epoch)
            if unchanged_snapshot:
                state["verify_failed_snapshot"] = current_snapshot
                state["verify_failed_epoch"] = state["change_epoch"]
    mark_processed(state, tool_use_id)


def terminal_event(state, payload, succeeded):
    if not current_prompt(state, payload):
        return
    tool_name = payload.get("tool_name")
    if tool_name == "AskUserQuestion":
        if succeeded:
            reset_work_phase(state)
        return
    if tool_name == PI_TOOL:
        finish_pi(state, payload, succeeded)
    else:
        finish_work(state, payload, succeeded)


def has_running_pi_task(payload):
    tasks = payload.get("background_tasks", [])
    if not isinstance(tasks, list):
        return False
    for task in tasks:
        if not isinstance(task, dict):
            continue
        status = str(task.get("status", "")).lower()
        task_type = str(task.get("type", "")).lower()
        server = str(task.get("server", "")).lower()
        tool = str(task.get("tool", "")).lower()
        if (
            status in {"pending", "starting", "running", "in_progress"}
            and task_type in {"mcp", "mcp_task"}
            and server == "pi"
            and tool == "subagent"
        ):
            return True
    return False


def stop_event(state, payload):
    if not current_prompt(state, payload):
        return None
    if fresh_pi_inflight(state) or has_running_pi_task(payload):
        return None
    if not state["verification_required"]:
        return None

    snapshot = worktree_snapshot(payload)
    if snapshot == "clean" or snapshot in {
        state["verified_snapshot"],
        state["verify_failed_snapshot"],
    }:
        state["verification_required"] = False
        return None

    epoch = state["change_epoch"]
    if state["verified_epoch"] == epoch or state["verify_failed_epoch"] == epoch:
        state["verification_required"] = False
        return None

    if state["stop_block_epoch"] != epoch:
        state["stop_block_epoch"] = epoch
        state["stop_blocks"] = 0
    if state["stop_blocks"] >= STOP_BLOCK_LIMIT:
        return None
    state["stop_blocks"] += 1

    return {
        "decision": "block",
        "reason": (
            "High-risk, broad, or externally applied changes still require independent "
            "Pi verification. Call mcp__pi__subagent with role=verify and a self-contained "
            "brief covering the "
            "completed changes and validation evidence. If Pi is unavailable, attempt the "
            "verify call once so the routing gate can fail open. Do not merely claim that "
            "verification was performed."
        ),
    }


def reminder_output():
    return {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": REMINDER,
        }
    }


def read_payload():
    try:
        value = json.load(sys.stdin)
        return value if isinstance(value, dict) else None
    except (json.JSONDecodeError, OSError):
        return None


def main():
    action = sys.argv[1] if len(sys.argv) == 2 else ""
    payload = read_payload()
    if payload is None:
        return

    output = None
    try:
        with locked_session(payload) as (state, path):
            if state is None:
                output = reminder_output() if action == "prompt" else None
            elif action == "cleanup":
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
            else:
                if action == "prompt":
                    prompt_id = payload.get("prompt_id")
                    if not isinstance(prompt_id, str) or not prompt_id:
                        state["legacy_prompt_seq"] += 1
                        prompt_id = f"legacy-{state['legacy_prompt_seq']}"
                    start_prompt(state, prompt_id)
                    output = reminder_output()
                elif action == "pre":
                    output = pre_tool(state, payload)
                elif action == "post":
                    terminal_event(state, payload, True)
                elif action == "failure":
                    terminal_event(state, payload, False)
                elif action == "stop":
                    output = stop_event(state, payload)
                save_state(path, state)
    except Exception:
        output = reminder_output() if action == "prompt" else None

    if output is not None:
        print(json.dumps(output, separators=(",", ":")))


if __name__ == "__main__":
    main()
