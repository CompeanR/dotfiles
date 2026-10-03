import { spawn } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_LINES,
  type ExtensionAPI,
  truncateHead,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const ALLOWED_TOOLS = "mcp__claude_design Read Glob Grep";

type ClaudeResult = {
  result?: string;
  session_id?: string;
  total_cost_usd?: number;
  is_error?: boolean;
  num_turns?: number;
};

type ClaudeDesignDetails = {
  sessionId?: string;
  costUsd?: number;
  turns?: number;
  fullOutputPath?: string;
};

function runClaude(prompt: string, sessionId: string | undefined, cwd: string, signal?: AbortSignal): Promise<ClaudeResult> {
  const args = ["-p", "--output-format", "json", "--allowedTools", ALLOWED_TOOLS];
  if (sessionId) args.push("--resume", sessionId);

  return new Promise((resolve, reject) => {
    const child = spawn("claude", args, { cwd, signal, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      try {
        resolve(JSON.parse(stdout) as ClaudeResult);
      } catch {
        reject(new Error(`claude exited with code ${code}: ${(stderr || stdout).trim().slice(0, 2000)}`));
      }
    });
    child.stdin.end(prompt);
  });
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "claude_design",
    label: "Claude Design",
    description:
      "Work with Claude Design (Anthropic's design tool) through a headless Claude Code session that has the Claude Design MCP. " +
      "Use it to create or iterate design projects, list projects, or read a design's files and specs so you can implement them. " +
      "Write `task` as a complete brief: Claude starts without this conversation's context. It can read the current repo (Read/Glob/Grep) but cannot edit it. " +
      "Pass the returned sessionId to continue the same Claude session.",
    parameters: Type.Object({
      task: Type.String({ description: "Self-contained instruction for the Claude Design session." }),
      sessionId: Type.Optional(Type.String({ description: "Claude session id from a previous call, to continue it." })),
    }),

    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      onUpdate?.({ content: [{ type: "text", text: "Claude Design session running…" }], details: undefined });

      const result = await runClaude(params.task, params.sessionId, ctx.cwd, signal);
      const output = result.result ?? "";
      if (result.is_error) throw new Error(output || "Claude Design session failed.");

      const details: ClaudeDesignDetails = {
        sessionId: result.session_id,
        costUsd: result.total_cost_usd,
        turns: result.num_turns,
      };

      const truncation = truncateHead(output, { maxLines: DEFAULT_MAX_LINES, maxBytes: DEFAULT_MAX_BYTES });
      let text = truncation.content;
      if (truncation.truncated) {
        details.fullOutputPath = join(await mkdtemp(join(tmpdir(), "pi-claude-design-")), "output.md");
        await writeFile(details.fullOutputPath, output, "utf8");
        text += `\n\n[Output truncated. Full output: ${details.fullOutputPath}]`;
      }

      const cost = details.costUsd === undefined ? "" : `, cost $${details.costUsd.toFixed(4)}`;
      text += `\n\n[sessionId: ${details.sessionId}${cost}]`;
      return { content: [{ type: "text", text }], details };
    },
  });
}
