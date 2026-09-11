import { spawn } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { resolve } from "node:path";

export const ROLE_NAMES = Object.freeze(["explore", "apply", "design", "verify"]);
export const DEFAULT_TIMEOUT_MS = 600000;

export class SubagentError extends Error {
  constructor(code, message, options = {}) {
    super(message, options.cause !== undefined ? { cause: options.cause } : undefined);
    this.name = "SubagentError";
    this.code = code;
    if (options.details !== undefined) this.details = options.details;
  }
}

// Minimal frontmatter reader. The role files use a fixed, simple shape
// (scalar `name`/`description`, a `tools:` block list), so a real YAML parser
// would be a dependency bought for nothing.
export function parseRoleFile(raw) {
  // Normalize CRLF and strip a BOM before anything else. Both would otherwise
  // defeat the `^---\n` match below and silently yield an all-empty parse --
  // including an empty tool list, which is the dangerous case (see
  // toolsDeclared).
  const text = raw.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");

  const m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (!m) return { description: "", tools: [], toolsDeclared: false, returns: "" };
  const [, frontmatter, body] = m;

  const descMatch = frontmatter.match(/^description:\s*(.+)$/m);
  const description = descMatch ? descMatch[1].trim().replace(/^["']|["']$/g, "") : "";

  const unquote = (s) => s.trim().replace(/^["']|["']$/g, "");
  const tools = [];
  const toolsDeclared = /^tools:/m.test(frontmatter);
  let inTools = false;
  for (const line of frontmatter.split("\n")) {
    const head = line.match(/^tools:\s*(.*)$/);
    if (head) {
      // Accept the inline form `tools: [read, grep]` as well as a block list.
      const inline = head[1].trim();
      if (inline.startsWith("[")) {
        for (const item of inline.replace(/^\[|\]$/g, "").split(",")) {
          if (item.trim()) tools.push(unquote(item));
        }
      } else {
        inTools = true;
      }
      continue;
    }
    if (inTools) {
      const item = line.match(/^\s+-\s+(.+?)\s*$/);
      if (item) { tools.push(unquote(item[1])); continue; }
      if (line.trim() !== "") inTools = false;
    }
  }

  // The "## Return" section is the contract the caller must write the brief
  // against, so it is surfaced in the tool description rather than left for
  // the caller to go read. Split on headings rather than matching a lazy
  // range: an `m`-flagged `$` matches at every line end, which collapses the
  // range to nothing.
  let returns = "";
  for (const section of body.split(/^##\s+/m).slice(1)) {
    const nl = section.indexOf("\n");
    const heading = (nl === -1 ? section : section.slice(0, nl)).trim();
    if (/^return$/i.test(heading)) {
      returns = nl === -1 ? "" : section.slice(nl + 1).trim();
      break;
    }
  }

  return { description, tools, toolsDeclared, returns };
}

function defaultOnWarning(message) {
  process.stderr.write(message);
}

export function loadRoleConfig({
  settingsPath,
  agentsDir,
  roleNames = ROLE_NAMES,
  onWarning,
} = {}) {
  const warn = onWarning ?? defaultOnWarning;
  const names = roleNames ?? ROLE_NAMES;
  const roles = {};

  try {
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    const overrides = settings?.subagents?.agentOverrides ?? {};

    for (const role of names) {
      // Per-role guard: one unreadable file must not take down every role.
      try {
        const file = resolve(agentsDir, `work-${role}.md`);
        if (!existsSync(file)) continue;
        const override = overrides[`work-${role}`] ?? {};
        if (!override.model) continue;
        roles[role] = {
          file,
          model: override.model,
          thinking: override.thinking ?? "medium",
          ...parseRoleFile(readFileSync(file, "utf8")),
        };

        // Fail closed on an empty allowlist, whatever the reason. `--tools` is
        // omitted when the list is empty and omitting it grants pi's FULL tool
        // surface, so "we couldn't find any tools" must never mean "run
        // unrestricted".
        //
        // Checking `tools.length` rather than only the `toolsDeclared` flag is
        // deliberate: `toolsDeclared` is `/^tools:/m`, so an indented `  tools:`,
        // a `Tools:`, a `tools :`, or a file whose frontmatter delimiters are
        // malformed all report "not declared" and would otherwise sail straight
        // past the guard into an unrestricted launch. Every role in ROLES is
        // meant to be restricted, so an empty list is always a config error.
        if (roles[role].tools.length === 0) {
          roles[role].configError =
            `role "${role}": no tool allowlist could be parsed from ${file}` +
            (roles[role].toolsDeclared
              ? ` (a "tools:" key is present but produced no entries).`
              : ` (no line-start "tools:" key was found -- check for indentation,` +
                ` capitalization, a space before the colon, or malformed "---" delimiters).`) +
            ` Refusing to run, because omitting --tools would grant this role every tool pi has.` +
            ` Expected LF line endings and either an indented block list or "tools: [a, b]".`;
        }
      } catch (err) {
        warn(`pi-subagent: skipping role ${role}: ${err.message}\n`);
      }
    }
  } catch (err) {
    return {
      roles,
      roleNames: names,
      loadError: `failed to read pi config: ${err.message}`,
    };
  }

  return {
    roles,
    roleNames: names,
    loadError: Object.keys(roles).length === 0
      ? `no usable work-<role> entries found in ${settingsPath}`
      : null,
  };
}

export function buildSubagentDescription(roleConfig) {
  const lines = [
    "Delegate a scoped subtask to a pi sub-agent running on a non-Claude model.",
    "Use this instead of the Agent/Task tool when a task suits a different model",
    "than the orchestrator. Independent roles can be called in parallel in one block.",
    "",
    "The sub-agent inherits NO project context, skills, or conversation history.",
    "The brief must be self-contained: the delegated goal, the context it needs,",
    "constraints, and the return shape you want.",
    "",
    "Roles (model + thinking come from pi/settings.json):",
  ];

  for (const [role, cfg] of Object.entries(roleConfig)) {
    lines.push(`  ${role} — ${cfg.model} (thinking: ${cfg.thinking})`);
    if (cfg.description) lines.push(`      ${cfg.description}`);
    if (cfg.returns) {
      const compact = cfg.returns
        .replace(/^Provide:?\s*/i, "")
        .split("\n")
        .map((l) => l.trim())
        .filter(Boolean)
        .join(" ")
        .replace(/\s+/g, " ");
      lines.push(`      Returns: ${compact}`);
    }
  }

  lines.push(
    "",
    "NO ROLE IS MECHANICALLY READ-ONLY. explore/design/verify are read-only by",
    "contract only -- by prompt, not by enforcement. Two separate reasons, both",
    "verified by test:",
    "  - cursor/* roles (explore, apply): the --tools allowlist does NOT apply to",
    "    Cursor SDK host tools. These roles really do have Write, StrReplace,",
    "    Delete and Task available, whatever the role file says.",
    "  - openai-codex/* roles (design, verify): the allowlist IS enforced exactly,",
    "    but it includes bash, and bash writes files.",
    "So when a task touches installers, setup/init subcommands, config writers, or",
    "anything you would not want edited, say so explicitly in the brief -- and do",
    "not rely on the role name to prevent writes.",
  );

  return lines.join("\n");
}

function canonicalCwd(cwd) {
  try {
    return realpathSync(cwd);
  } catch {
    return cwd;
  }
}

function runProcess(cmd, args, { cwd, timeoutMs, signal }) {
  return new Promise((resolvePromise, reject) => {
    let settled = false;
    let timedOut = false;
    let child;
    let timer;
    let onAbort;

    const cleanup = () => {
      if (timer !== undefined) clearTimeout(timer);
      if (signal && onAbort) signal.removeEventListener("abort", onAbort);
    };

    const settleResolve = (result) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolvePromise(result);
    };

    const settleReject = (err) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(err);
    };

    try {
      child = spawn(cmd, args, {
        cwd,
        env: process.env,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (err) {
      settleResolve({ code: -1, stdout: "", stderr: `spawn failed: ${err.message}`, timedOut: false });
      return;
    }

    let stdout = "";
    let stderr = "";

    timer = setTimeout(() => {
      timedOut = true;
      try { child.kill("SIGKILL"); } catch { /* already gone */ }
    }, timeoutMs);

    onAbort = () => {
      try { child.kill("SIGKILL"); } catch { /* already gone */ }
      settleReject(new SubagentError("aborted", "sub-agent aborted"));
    };

    if (signal) {
      signal.addEventListener("abort", onAbort, { once: true });
      if (signal.aborted) {
        onAbort();
      }
    }

    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("error", (err) => {
      settleResolve({
        code: -1,
        stdout,
        stderr: `${stderr}\nspawn error: ${err.message}`,
        timedOut,
      });
    });
    child.on("close", (code) => {
      settleResolve({ code, stdout, stderr, timedOut });
    });
  });
}

function interpretResult(r, timeoutMs) {
  if (r.timedOut) {
    throw new SubagentError("timeout", `sub-agent timed out after ${timeoutMs}ms\n${r.stderr.trim()}`);
  }
  if (r.code !== 0) {
    throw new SubagentError("process_exit", `pi exited ${r.code}\n${r.stderr.trim() || r.stdout.trim()}`);
  }
  const out = r.stdout.trim();
  if (!out) {
    throw new SubagentError("empty_output", `sub-agent produced no output\n${r.stderr.trim()}`);
  }
  return out;
}

export function createSubagentService(options) {
  const {
    settingsPath,
    agentsDir,
    dispatchPath,
    piCommand = "pi",
    defaultTimeoutMs = DEFAULT_TIMEOUT_MS,
    roleNames = ROLE_NAMES,
    allowWatch = true,
    enforceSingleWriterPerCwd = false,
    onWarning,
  } = options;

  const loaded = loadRoleConfig({ settingsPath, agentsDir, roleNames, onWarning });
  const { roles, loadError } = loaded;
  const names = loaded.roleNames;
  const description = buildSubagentDescription(roles);
  const activeWriterCwds = new Set();

  async function dispatch(args = {}, runtime = {}) {
    if (loadError) throw new SubagentError("config", loadError);

    const role = args.role;
    const brief = args.brief;

    if (!role || !roles[role]) {
      throw new SubagentError(
        "unknown_role",
        `unknown role ${JSON.stringify(role ?? null)}; available: ${names.join(", ")}`,
      );
    }
    if (typeof brief !== "string" || brief.trim() === "") {
      throw new SubagentError("invalid_brief", "brief is required and must be a non-empty string");
    }

    // Re-checked on every dispatch, not just at load, so a role that failed the
    // allowlist check can never be reached by any code path.
    if (roles[role].configError) {
      throw new SubagentError("config", roles[role].configError);
    }

    if (args.watch === true && !allowWatch) {
      throw new SubagentError("watch_unsupported", "watch mode is not supported in this context");
    }

    const cwd = typeof args.cwd === "string" && existsSync(args.cwd)
      ? args.cwd
      : (runtime.cwd ?? process.cwd());
    const timeoutMs = Number.isFinite(args.timeout_ms) ? args.timeout_ms : defaultTimeoutMs;
    const cfg = roles[role];
    const watch = args.watch === true;
    const details = {
      role,
      cwd,
      model: cfg.model,
      thinking: cfg.thinking,
      watch,
      timeoutMs,
    };

    // ASSERT non-empty tools immediately before building argv. A second,
    // independent check from the load-time one. No code path may ever spawn
    // without --tools: omitting it grants pi's full tool surface.
    if (!cfg.tools.length) {
      throw new SubagentError(
        "config",
        cfg.configError
          ?? `role "${role}": empty tool allowlist; refusing to spawn without --tools`,
      );
    }

    const signal = runtime.signal;
    if (signal?.aborted) {
      throw new SubagentError("aborted", "sub-agent aborted");
    }

    const toolsCsv = cfg.tools.join(",");
    let cmd;
    let spawnArgs;
    let spawnTimeout = timeoutMs;

    if (watch) {
      if (!dispatchPath || !existsSync(dispatchPath)) {
        throw new SubagentError(
          "config",
          `watch mode needs ${dispatchPath}, which is missing`,
        );
      }
      // Hand dispatch the allowlist this service already parsed and vetted,
      // instead of letting it re-parse the same frontmatter with its own YAML
      // reader. Two parsers of one file means two chances to disagree, and only
      // one of them is behind the fail-closed check above.
      cmd = dispatchPath;
      spawnArgs = [
        role, brief,
        "--cwd", cwd,
        "--timeout", String(timeoutMs),
        "--tools", toolsCsv,
      ];
      // Give dispatch.sh's own herdr `agent wait` a chance to finish and report
      // before we pull the rug out from under it.
      spawnTimeout = timeoutMs + 60000;
    } else {
      cmd = piCommand;
      spawnArgs = [
        "-p",
        "--model", cfg.model,
        "--thinking", cfg.thinking,
        "--append-system-prompt", cfg.file,
        "--no-session",
        // The roles already set inheritSkills/inheritProjectContext false, so
        // loading the user's skills, prompt templates and CLAUDE.md/AGENTS.md
        // would contradict the role contract as well as cost startup time.
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--tools", toolsCsv,
        brief,
      ];
    }

    let writerKey;
    if (enforceSingleWriterPerCwd && role === "apply") {
      writerKey = canonicalCwd(cwd);
      if (activeWriterCwds.has(writerKey)) {
        throw new SubagentError("writer_busy", `another apply sub-agent is already running in ${writerKey}`);
      }
      activeWriterCwds.add(writerKey);
    }

    try {
      const r = await runProcess(cmd, spawnArgs, { cwd, timeoutMs: spawnTimeout, signal });
      const text = interpretResult(r, timeoutMs);
      return { text, details };
    } finally {
      if (writerKey !== undefined) activeWriterCwds.delete(writerKey);
    }
  }

  return { roles, roleNames: names, loadError, description, dispatch };
}
