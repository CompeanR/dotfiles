#!/usr/bin/env node
// MCP stdio server exposing pi-backed sub-agents as a native tool call.
//
// Why this exists: Claude Code's own Agent/Task tool only spawns Claude
// models, and .claude/agents/*.md only accepts Claude model names. An MCP
// tool is the only surface where delegating to a non-Claude model looks and
// costs the same as a native sub-agent call -- one typed call, schema already
// in context, several in parallel in one block, no skill load and no file
// reads first.
//
// pi/settings.json and pi/agents/work-<role>.md stay the single source of
// truth: the role table and return contracts in the tool description are
// generated from them at startup, so there is nothing to keep in sync.
//
// Zero dependencies on purpose -- this lives in dotfiles and must work on a
// fresh machine without an npm install.

import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const DOTFILES = resolve(HERE, "../../..");
const PI_SETTINGS = resolve(DOTFILES, "pi/settings.json");
const AGENTS_DIR = resolve(DOTFILES, "pi/agents");
const DISPATCH = resolve(HERE, "dispatch.sh");

const ROLES = ["explore", "apply", "design", "verify"];
const DEFAULT_TIMEOUT_MS = 600000;

// --- role config, read from pi's own files -------------------------------

// Minimal frontmatter reader. The role files use a fixed, simple shape
// (scalar `name`/`description`, a `tools:` block list), so a real YAML parser
// would be a dependency bought for nothing.
function parseRoleFile(raw) {
  // Normalize CRLF and strip a BOM before anything else. Both would otherwise
  // defeat the `^---\n` match below and silently yield an all-empty parse --
  // including an empty tool list, which is the dangerous case (see
  // toolsDeclared).
  const text = raw.replace(/^﻿/, "").replace(/\r\n/g, "\n");

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

function loadRoles() {
  const settings = JSON.parse(readFileSync(PI_SETTINGS, "utf8"));
  const overrides = settings?.subagents?.agentOverrides ?? {};
  const roles = {};

  for (const role of ROLES) {
    // Per-role guard: one unreadable file must not take down every role.
    try {
      const file = resolve(AGENTS_DIR, `work-${role}.md`);
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
      process.stderr.write(`pi-subagent: skipping role ${role}: ${err.message}\n`);
    }
  }
  return roles;
}

let ROLE_CONFIG = {};
let loadError = null;
try {
  ROLE_CONFIG = loadRoles();
  if (Object.keys(ROLE_CONFIG).length === 0) {
    loadError = `no usable work-<role> entries found in ${PI_SETTINGS}`;
  }
} catch (err) {
  loadError = `failed to read pi config: ${err.message}`;
}

function buildDescription() {
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

  for (const [role, cfg] of Object.entries(ROLE_CONFIG)) {
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

// --- running a role ------------------------------------------------------

function runProcess(cmd, args, { cwd, timeoutMs, env }) {
  return new Promise((resolvePromise) => {
    let child;
    try {
      child = spawn(cmd, args, {
        cwd,
        env: env ?? process.env,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (err) {
      resolvePromise({ code: -1, stdout: "", stderr: `spawn failed: ${err.message}`, timedOut: false });
      return;
    }

    let stdout = "";
    let stderr = "";
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, timeoutMs);

    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("error", (err) => {
      clearTimeout(timer);
      resolvePromise({ code: -1, stdout, stderr: `${stderr}\nspawn error: ${err.message}`, timedOut });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolvePromise({ code, stdout, stderr, timedOut });
    });
  });
}

// Default path: pi in non-interactive print mode as a plain subprocess.
// No pane, no tab, no scrollback scraping -- and none of the TUI-driving
// failure modes documented in the herdr-subagent NOTES.md.
async function runPrint(cfg, { brief, cwd, timeoutMs }) {
  const args = [
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
  ];
  if (cfg.tools.length > 0) args.push("--tools", cfg.tools.join(","));
  args.push(brief);

  const r = await runProcess("pi", args, { cwd, timeoutMs });

  if (r.timedOut) {
    return { isError: true, text: `sub-agent timed out after ${timeoutMs}ms\n${r.stderr.trim()}` };
  }
  if (r.code !== 0) {
    return { isError: true, text: `pi exited ${r.code}\n${r.stderr.trim() || r.stdout.trim()}` };
  }
  const out = r.stdout.trim();
  if (!out) {
    return { isError: true, text: `sub-agent produced no output\n${r.stderr.trim()}` };
  }
  return { isError: false, text: out };
}

// watch:true path: the herdr pane lifecycle, so the run is visible in the
// agent panel. Slower (pi TUI cold start plus pane setup) but inspectable.
async function runWatched(role, cfg, { brief, cwd, timeoutMs }) {
  if (!existsSync(DISPATCH)) {
    return { isError: true, text: `watch mode needs ${DISPATCH}, which is missing` };
  }
  // Hand dispatch.sh the allowlist this server already parsed and vetted,
  // instead of letting it re-parse the same frontmatter with its own YAML
  // reader. Two parsers of one file means two chances to disagree, and only
  // one of them is behind the fail-closed check above.
  const args = [
    role, brief,
    "--cwd", cwd,
    "--timeout", String(timeoutMs),
    "--tools", cfg.tools.join(","),
  ];
  // Give dispatch.sh's own herdr `agent wait` a chance to finish and report
  // before we pull the rug out from under it.
  const r = await runProcess(DISPATCH, args, { cwd, timeoutMs: timeoutMs + 60000 });

  if (r.timedOut) {
    return { isError: true, text: `watched sub-agent timed out\n${r.stderr.trim()}` };
  }
  if (r.code !== 0) {
    return { isError: true, text: `dispatch.sh exited ${r.code}\n${r.stderr.trim()}` };
  }
  const out = r.stdout.trim();
  if (!out) {
    return { isError: true, text: `sub-agent produced no output\n${r.stderr.trim()}` };
  }
  return { isError: false, text: out };
}

async function callSubagent(args) {
  if (loadError) return { isError: true, text: loadError };

  const role = args?.role;
  const brief = args?.brief;

  if (!role || !ROLE_CONFIG[role]) {
    return {
      isError: true,
      text: `unknown role ${JSON.stringify(role ?? null)}; available: ${Object.keys(ROLE_CONFIG).join(", ")}`,
    };
  }
  if (typeof brief !== "string" || brief.trim() === "") {
    return { isError: true, text: "brief is required and must be a non-empty string" };
  }

  // Re-checked on every dispatch, not just at load, so a role that failed the
  // allowlist check can never be reached by any code path.
  if (ROLE_CONFIG[role].configError) {
    return { isError: true, text: ROLE_CONFIG[role].configError };
  }

  const cwd = args.cwd && existsSync(args.cwd) ? args.cwd : process.cwd();
  const timeoutMs = Number.isFinite(args.timeout_ms) ? args.timeout_ms : DEFAULT_TIMEOUT_MS;
  const cfg = ROLE_CONFIG[role];

  return args.watch === true
    ? runWatched(role, cfg, { brief, cwd, timeoutMs })
    : runPrint(cfg, { brief, cwd, timeoutMs });
}

// --- MCP stdio plumbing --------------------------------------------------

const PROTOCOL_VERSION = "2025-06-18";

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function reply(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

const TOOLS = [
  {
    name: "subagent",
    description: buildDescription(),
    inputSchema: {
      type: "object",
      properties: {
        role: {
          type: "string",
          enum: Object.keys(ROLE_CONFIG),
          description: "Which role to delegate to. See the role table above.",
        },
        brief: {
          type: "string",
          description:
            "Self-contained brief: the delegated goal, the context the agent needs, constraints, and the exact return shape. The agent sees no project context, skills, or history.",
        },
        cwd: {
          type: "string",
          description: "Working directory for the sub-agent. Defaults to the current directory.",
        },
        watch: {
          type: "boolean",
          description:
            "Run in a visible herdr pane so the agent shows up in the agent panel. Slower (pi TUI cold start plus pane setup). Default false, which runs pi headless as a subprocess.",
        },
        timeout_ms: {
          type: "number",
          description: `Max run time before the sub-agent is killed. Default ${DEFAULT_TIMEOUT_MS}.`,
        },
      },
      required: ["role", "brief"],
      additionalProperties: false,
    },
  },
];

async function handleRequest(msg) {
  const { id, method, params } = msg;

  switch (method) {
    case "initialize":
      reply(id, {
        protocolVersion: params?.protocolVersion ?? PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: "pi-subagent", version: "1.0.0" },
      });
      return;

    case "ping":
      reply(id, {});
      return;

    case "tools/list":
      reply(id, { tools: TOOLS });
      return;

    case "tools/call": {
      if (params?.name !== "subagent") {
        replyError(id, -32602, `unknown tool: ${params?.name}`);
        return;
      }
      // Deliberately not awaited by the read loop: concurrent tool calls
      // must run in parallel, not queue behind each other.
      const out = await callSubagent(params?.arguments ?? {});
      reply(id, { content: [{ type: "text", text: out.text }], isError: out.isError });
      return;
    }

    default:
      replyError(id, -32601, `method not found: ${method}`);
  }
}

// A sub-agent run outlives the request that started it, so stdin closing is
// not permission to exit -- drain in-flight work first, or a client
// disconnect (and any piped test) silently loses the result.
let pending = 0;
let stdinClosed = false;

function maybeExit() {
  if (stdinClosed && pending === 0) process.exit(0);
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let idx;
  while ((idx = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;

    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue; // not framed JSON-RPC; nothing useful to reply to
    }

    // Notifications carry no id and expect no response.
    if (msg.id === undefined || msg.id === null) continue;

    pending += 1;
    handleRequest(msg)
      .catch((err) => {
        replyError(msg.id, -32603, `internal error: ${err.message}`);
      })
      .finally(() => {
        pending -= 1;
        maybeExit();
      });
  }
});

process.stdin.on("end", () => {
  stdinClosed = true;
  maybeExit();
});
