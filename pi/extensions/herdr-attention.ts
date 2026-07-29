import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
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

function reportAgent(state: "blocked" | "working", message?: string): void {
  if (!herdrEnabled()) return;
  const request = {
    id: `herdr-attention:${Date.now()}:${Math.random().toString(36).slice(2)}`,
    method: "pane.report_agent",
    params: {
      pane_id: paneId,
      source,
      agent: "pi",
      state,
      message,
      seq: nextHerdrReportSequence(),
    },
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

  function markBlocked(toolName: string, toolCallId: string, args: unknown): void {
    if (!isAttentionTool(toolName) || activeToolCalls.has(toolCallId)) {
      return;
    }
    activeToolCalls.add(toolCallId);
    const label = attentionLabel(args);
    // Event for herdr-agent-state (blockedCount / restore after ask).
    pi.events.emit("herdr:blocked", { active: true, label });
    // Direct report: Cursor MCP asks can miss the event-bus path; Herdr CLI
    // accepts blocked when seq is high enough (verified manually).
    reportAgent("blocked", label);
  }

  function clearBlocked(toolName: string, toolCallId: string): void {
    if (!isAttentionTool(toolName) || !activeToolCalls.delete(toolCallId)) {
      return;
    }
    pi.events.emit("herdr:blocked", { active: false });
    if (activeToolCalls.size === 0) {
      // Hand control back; agent-state will settle on working/idle.
      reportAgent("working");
    }
  }

  pi.on("tool_call", (event) => {
    markBlocked(event.toolName, event.toolCallId, event.input);
  });

  pi.on("tool_execution_start", (event) => {
    markBlocked(event.toolName, event.toolCallId, event.args);
  });

  pi.on("tool_result", (event) => {
    clearBlocked(event.toolName, event.toolCallId);
  });

  pi.on("tool_execution_end", (event) => {
    clearBlocked(event.toolName, event.toolCallId);
  });

  pi.on("session_shutdown", () => {
    if (activeToolCalls.size > 0) {
      for (const _id of activeToolCalls) {
        pi.events.emit("herdr:blocked", { active: false });
      }
      activeToolCalls.clear();
      reportAgent("working");
    }
  });
}
