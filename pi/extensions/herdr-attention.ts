import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import net from "node:net";
import { nextHerdrReportSequence } from "./lib/herdr-report-sequence.ts";

const ATTENTION_TOOLS = new Set(["cursor_ask_question", "ask_user_question"]);
const MAX_LABEL_LENGTH = 120;

const HERDR_ENV = process.env.HERDR_ENV;
const socketPath = process.env.HERDR_SOCKET_PATH;
const socketEndpoint =
  process.platform === "win32" && socketPath ? `\\\\.\\pipe\\${socketPath}` : socketPath;
const paneId = process.env.HERDR_PANE_ID;
const source = "herdr:pi";

type QuestionArgs = {
  question?: unknown;
  prompt?: unknown;
  questions?: Array<{ question?: unknown; prompt?: unknown }>;
};

function toolBaseName(name: string): string {
  // Cursor MCP bridge exposes tools as pi__<name>; Pi lifecycle uses bare names.
  return name.startsWith("pi__") ? name.slice(4) : name;
}

function isAttentionTool(toolName: string): boolean {
  return ATTENTION_TOOLS.has(toolName) || ATTENTION_TOOLS.has(toolBaseName(toolName));
}

function firstText(...values: unknown[]): string | undefined {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return undefined;
}

function attentionLabel(args: unknown): string {
  const input = (args && typeof args === "object" ? args : {}) as QuestionArgs;
  const firstQuestion = Array.isArray(input.questions) ? input.questions[0] : undefined;
  const question = firstText(
    input.question,
    input.prompt,
    firstQuestion?.question,
    firstQuestion?.prompt,
  );
  const label = question ? `Needs your input: ${question}` : "Needs your input";
  return label.length <= MAX_LABEL_LENGTH
    ? label
    : `${label.slice(0, MAX_LABEL_LENGTH - 1)}…`;
}

function herdrEnabled(): boolean {
  return HERDR_ENV === "1" && !!socketEndpoint && !!paneId;
}

function withSessionRef(
  params: Record<string, unknown>,
  ctx: ExtensionContext,
): Record<string, unknown> | undefined {
  try {
    const file = ctx?.sessionManager?.getSessionFile?.();
    if (typeof file === "string" && file.startsWith("/")) {
      return { ...params, agent_session_path: file };
    }
  } catch {
    // Fall back to the session id when a path is unavailable.
  }

  try {
    const id = ctx?.sessionManager?.getSessionId?.();
    if (typeof id === "string" && id.length > 0) {
      return { ...params, agent_session_id: id };
    }
  } catch {
    // Ignore and leave lifecycle reporting to herdr-agent-state.
  }

  return undefined;
}

function reportAgent(
  state: "blocked" | "working",
  message: string | undefined,
  ctx: ExtensionContext,
): void {
  if (!herdrEnabled()) return;
  const params = withSessionRef({
    pane_id: paneId,
    source,
    agent: "pi",
    state,
    message,
    seq: nextHerdrReportSequence(),
  }, ctx);
  if (!params) return;

  const request = {
    id: `herdr-attention:${Date.now()}:${Math.random().toString(36).slice(2)}`,
    method: "pane.report_agent",
    params,
  };
  const payload = `${JSON.stringify(request)}\n`;
  try {
    const client = net.createConnection(socketEndpoint as string);
    client.setTimeout(1500);
    client.on("error", () => {
      try {
        client.destroy();
      } catch {
        // ignore
      }
    });
    client.on("timeout", () => {
      try {
        client.destroy();
      } catch {
        // ignore
      }
    });
    client.on("connect", () => {
      client.end(payload);
    });
  } catch {
    // Never interrupt the ask UI if Herdr is unreachable.
  }
}

export default function (pi: ExtensionAPI) {
  const activeToolCalls = new Set<string>();

  function markBlocked(
    toolName: string,
    toolCallId: string,
    args: unknown,
    ctx: ExtensionContext,
  ): void {
    if (!isAttentionTool(toolName) || activeToolCalls.has(toolCallId)) {
      return;
    }
    activeToolCalls.add(toolCallId);
    const label = attentionLabel(args);
    // Event for herdr-agent-state (blockedCount / restore after ask).
    pi.events.emit("herdr:blocked", { active: true, label });
    // Full-lifecycle reports must retain the owning Pi session. A sessionless
    // blocked report causes Herdr 0.8 to drop the anchor and suppress recovery.
    reportAgent("blocked", label, ctx);
  }

  function clearBlocked(
    toolName: string,
    toolCallId: string,
    ctx: ExtensionContext,
  ): void {
    if (!isAttentionTool(toolName) || !activeToolCalls.delete(toolCallId)) {
      return;
    }
    pi.events.emit("herdr:blocked", { active: false });
    if (activeToolCalls.size === 0) {
      // Hand control back; agent-state will settle on working/idle.
      reportAgent("working", undefined, ctx);
    }
  }

  pi.on("tool_call", (event, ctx) => {
    markBlocked(event.toolName, event.toolCallId, event.input, ctx);
  });

  pi.on("tool_execution_start", (event, ctx) => {
    markBlocked(event.toolName, event.toolCallId, event.args, ctx);
  });

  pi.on("tool_result", (event, ctx) => {
    clearBlocked(event.toolName, event.toolCallId, ctx);
  });

  pi.on("tool_execution_end", (event, ctx) => {
    clearBlocked(event.toolName, event.toolCallId, ctx);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    if (activeToolCalls.size > 0) {
      for (const _id of activeToolCalls) {
        pi.events.emit("herdr:blocked", { active: false });
      }
      activeToolCalls.clear();
      reportAgent("working", undefined, ctx);
    }
  });
}
