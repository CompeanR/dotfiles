import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const ATTENTION_TOOLS = new Set(["cursor_ask_question", "ask_user_question"]);
const MAX_LABEL_LENGTH = 120;

type QuestionArgs = {
  question?: unknown;
  prompt?: unknown;
  questions?: Array<{ question?: unknown; prompt?: unknown }>;
};

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

export default function (pi: ExtensionAPI) {
  const activeToolCalls = new Set<string>();

  function markBlocked(toolName: string, toolCallId: string, args: unknown): void {
    if (!ATTENTION_TOOLS.has(toolName) || activeToolCalls.has(toolCallId)) {
      return;
    }
    activeToolCalls.add(toolCallId);
    pi.events.emit("herdr:blocked", {
      active: true,
      label: attentionLabel(args),
    });
  }

  function clearBlocked(toolName: string, toolCallId: string): void {
    if (!ATTENTION_TOOLS.has(toolName) || !activeToolCalls.delete(toolCallId)) {
      return;
    }
    pi.events.emit("herdr:blocked", { active: false });
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
    for (const _id of activeToolCalls) {
      pi.events.emit("herdr:blocked", { active: false });
    }
    activeToolCalls.clear();
  });
}
