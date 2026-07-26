import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFile, chmod, mkdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

const WEBHOOK_URL = "https://api.getmoshi.app/api/webhook";
const DEFAULT_LONG_TURN_SECONDS = 300;
const MAX_MESSAGE_LENGTH = 220;
// ponytail: no push on ask_user_question / cursor_ask_question — Herdr sidebar
// (herdr-attention) owns that signal; Moshi only for long-turn + /push-next.

function configuredThresholdMs(): number {
  const configured = Number(
    process.env.MOSHI_LONG_TURN_SECONDS ?? DEFAULT_LONG_TURN_SECONDS,
  );
  const seconds =
    Number.isFinite(configured) && configured >= 0
      ? configured
      : DEFAULT_LONG_TURN_SECONDS;
  return seconds * 1000;
}

function tokenPath(): string {
  return (
    process.env.MOSHI_PUSH_TOKEN_FILE ??
    join(homedir(), ".config", "moshi", "push-token")
  );
}

function logPath(): string {
  return join(homedir(), ".local", "state", "moshi", "completion-alert.log");
}

function truncate(value: string, limit = MAX_MESSAGE_LENGTH): string {
  const normalized = value.replace(/\s+/g, " ").trim();
  return normalized.length <= limit
    ? normalized
    : `${normalized.slice(0, limit - 1)}…`;
}

function textFromContent(value: unknown): string {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";

  return value
    .map((part) => {
      if (typeof part === "string") return part;
      if (!part || typeof part !== "object" || !("text" in part)) return "";
      const text = (part as { text?: unknown }).text;
      return typeof text === "string" ? text : "";
    })
    .filter(Boolean)
    .join(" ");
}

function textFromMessage(value: unknown): string {
  if (!value || typeof value !== "object") return "";
  const message = value as Record<string, unknown>;
  return textFromContent(message.content);
}

function formatDuration(milliseconds: number): string {
  const totalSeconds = Math.max(0, Math.round(milliseconds / 1000));
  if (totalSeconds < 60) return `${totalSeconds}s`;
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return seconds === 0 ? `${minutes}m` : `${minutes}m ${seconds}s`;
}

async function writeLog(
  level: "info" | "error",
  event: string,
  details: Record<string, unknown> = {},
): Promise<void> {
  const path = logPath();
  try {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    await appendFile(
      path,
      `${JSON.stringify({ timestamp: new Date().toISOString(), level, event, ...details })}\n`,
      { mode: 0o600 },
    );
    await chmod(path, 0o600);
  } catch {
    // Notification logging must never interrupt Pi.
  }
}

async function sendPush(
  title: string,
  message: string,
  reason: string,
): Promise<boolean> {
  try {
    const token = (await readFile(tokenPath(), "utf8")).trim();
    if (!token) throw new Error("push token file is empty");

    const response = await fetch(WEBHOOK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        token,
        title: truncate(title, 100),
        message: truncate(message),
      }),
      signal: AbortSignal.timeout(10_000),
    });

    if (!response.ok) {
      const body = truncate(await response.text(), 300);
      throw new Error(`HTTP ${response.status}${body ? `: ${body}` : ""}`);
    }

    await writeLog("info", "push_sent", {
      reason,
      title: truncate(title, 100),
    });
    return true;
  } catch (error) {
    await writeLog("error", "push_failed", {
      reason,
      error: error instanceof Error ? error.message : String(error),
    });
    return false;
  }
}

export default function moshiCompletionAlert(pi: ExtensionAPI): void {
  const longTurnThresholdMs = configuredThresholdMs();
  let pushNext = false;
  let runStartedAt: number | undefined;
  let prompt = "";
  let lastAssistantMessage = "";

  pi.registerCommand("push-next", {
    description: "Send a normal Moshi push when the next Pi turn finishes",
    handler: async (args, ctx) => {
      const action = args.trim().toLowerCase();

      if (action === "off" || action === "cancel") {
        pushNext = false;
        ctx.ui.notify("Next-turn Moshi alert cancelled", "info");
        await writeLog("info", "push_next_cancelled");
        return;
      }

      if (action === "status") {
        const threshold = formatDuration(longTurnThresholdMs);
        ctx.ui.notify(
          `Next-turn alert: ${pushNext ? "armed" : "off"}; long-turn threshold: ${threshold}`,
          "info",
        );
        return;
      }

      if (action) {
        ctx.ui.notify("Usage: /push-next [status|off]", "warning");
        return;
      }

      pushNext = true;
      ctx.ui.notify("Moshi will alert when the next Pi turn finishes", "info");
      await writeLog("info", "push_next_armed");
    },
  });

  pi.on("before_agent_start", (event) => {
    runStartedAt ??= Date.now();
    if (typeof event.prompt === "string" && event.prompt.trim()) {
      prompt = event.prompt.trim();
    }
  });

  pi.on("agent_end", (event) => {
    const messages = Array.isArray(event.messages) ? event.messages : [];
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const message = messages[index] as Record<string, unknown>;
      if (message?.role === "assistant") {
        lastAssistantMessage = textFromMessage(message);
        break;
      }
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    const startedAt = runStartedAt;
    const elapsedMs = startedAt === undefined ? 0 : Date.now() - startedAt;
    const explicit = pushNext;
    const longRunning =
      startedAt !== undefined && elapsedMs >= longTurnThresholdMs;

    pushNext = false;
    runStartedAt = undefined;

    if (!explicit && !longRunning) {
      prompt = "";
      lastAssistantMessage = "";
      return;
    }

    const project = basename(ctx.cwd) || "Pi";
    const reason = explicit ? "push-next" : "long-turn";
    const detail =
      lastAssistantMessage ||
      (prompt ? `Finished: ${prompt}` : "Pi finished its turn");
    await sendPush(
      `${project}: Pi completed in ${formatDuration(elapsedMs)}`,
      detail,
      reason,
    );

    prompt = "";
    lastAssistantMessage = "";
  });

  pi.on("session_shutdown", () => {
    pushNext = false;
    runStartedAt = undefined;
    prompt = "";
    lastAssistantMessage = "";
  });
}
