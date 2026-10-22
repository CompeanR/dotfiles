import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import {
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_LINES,
  type ExtensionAPI,
  truncateHead,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const ALLOWED_TOOLS = "mcp__claude_design Read Glob Grep";
const PULL_WORKSPACE = join(homedir(), ".cache", "pi-claude-design");
const PULL_TIMEOUT_MS = 15 * 60 * 1000;
const POLL_MS = 5000;
const run = promisify(execFile);

type PullResult = { version?: string; files?: string[]; error?: string };

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

async function startBackgroundClaude(prompt: string): Promise<string> {
  const { stdout, stderr } = await run("claude", ["--bg", "--permission-mode", "acceptEdits", prompt], {
    cwd: PULL_WORKSPACE,
    env: { ...process.env, CLAUDE_CODE_ARTIFACT_AUTO_OPEN: "0" },
  });
  const id = /backgrounded · (\w+)/.exec(stdout)?.[1];
  if (!id) throw new Error(`Could not start a background Claude session: ${(stderr || stdout).trim()}`);
  return id;
}

async function agentState(id: string): Promise<string | undefined> {
  const { stdout } = await run("claude", ["agents", "--json", "--all"]);
  const agents = JSON.parse(stdout) as { id: string; state: string }[];
  return agents.find((agent) => agent.id === id)?.state;
}

async function readPullResult(path: string): Promise<PullResult | undefined> {
  try {
    return JSON.parse(await readFile(path, "utf8")) as PullResult;
  } catch {
    return undefined;
  }
}

async function pullArtifact(url: string, dest: string, signal?: AbortSignal): Promise<PullResult> {
  const runId = randomUUID().slice(0, 8);
  const outDir = join(PULL_WORKSPACE, "out", runId);
  const resultPath = `${outDir}.json`;
  const prompt =
    `Read the artifact ${url} (its latest version) and save its own files (canvas.json and every file under project/, keeping their relative paths) into ./out/${runId}/. ` +
    `Do not publish or change the artifact, and don't ask questions. ` +
    `Last, write ./out/${runId}.json as {"version": "<version id you read>", "files": ["<relative paths written>"]}. ` +
    `If you can't read the artifact, write ./out/${runId}.json as {"error": "<why>"} instead.`;

  const id = await startBackgroundClaude(prompt);
  try {
    const deadline = Date.now() + PULL_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (signal?.aborted) throw new Error("Pull cancelled.");
      await new Promise((r) => setTimeout(r, POLL_MS));
      const result = await readPullResult(resultPath);
      if (result) {
        if (result.error) throw new Error(`Claude could not read the artifact: ${result.error}`);
        await cp(outDir, dest, { recursive: true, force: true });
        return result;
      }
      const state = await agentState(id);
      if (state === "done" || state === "stopped" || state === "failed") {
        if (await readPullResult(resultPath)) continue;
        throw new Error(`Background session ${id} ended (${state}) without pulling. Inspect it with \`claude attach ${id}\`.`);
      }
    }
    throw new Error(`Pull timed out after ${PULL_TIMEOUT_MS / 60000} minutes (session ${id}).`);
  } finally {
    await run("claude", ["stop", id]).catch(() => undefined);
    await rm(outDir, { recursive: true, force: true });
    await rm(resultPath, { force: true });
  }
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "claude_design_pull",
    label: "Claude Design pull",
    description:
      "Download a Claude Design artifact (https://claude.ai/artifact/...) into a project folder: project/canvas.json plus one .dc.html file per artboard. " +
      "Use it after the user finishes a design on claude.ai and gives you its URL, then implement from the pulled files. Takes 1-3 minutes.",
    parameters: Type.Object({
      url: Type.String({ description: "Artifact URL, e.g. https://claude.ai/artifact/Mj2extL2ZQHPt5JK5iYUjN" }),
      dir: Type.String({ description: "Destination folder, relative to the project root, e.g. design/settings-screen" }),
    }),

    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      onUpdate?.({ content: [{ type: "text", text: "Pulling the design through a background Claude session…" }], details: undefined });
      const dest = resolve(ctx.cwd, params.dir);
      const result = await pullArtifact(params.url, dest, signal);
      const files = (result.files ?? []).map((file) => `- ${join(params.dir, file)}`).join("\n");
      return {
        content: [{ type: "text", text: `Pulled version ${result.version ?? "unknown"} into ${params.dir}:\n${files}` }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "claude_design",
    label: "Claude Design",
    description:
      "Read Claude Design (Anthropic's design tool) through a headless Claude Code session that has the Claude Design MCP. " +
      "Read-only: use it to list projects and read a design's files and specs so you can implement them. " +
      "Never use it to create or edit designs. For new designs, use the design-prompt skill, then fetch the finished artifact with claude_design_pull. " +
      "Write `task` as a complete brief that asks for no changes: Claude starts without this conversation's context. It can read the current repo (Read/Glob/Grep) but cannot edit it. " +
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
