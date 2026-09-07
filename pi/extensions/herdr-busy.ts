// Sibling overlay for herdr-agent-state.ts (managed by herdr).
// Treats pi-subagents `herdr:busy` as semantic working after the parent settles.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import net from "node:net";
import { nextHerdrReportSequence } from "./lib/herdr-report-sequence.ts";

const HERDR_ENV = process.env.HERDR_ENV;
const socketPath = process.env.HERDR_SOCKET_PATH;
const socketEndpoint =
  process.platform === "win32" && socketPath ? `\\\\.\\pipe\\${socketPath}` : socketPath;
const paneId = process.env.HERDR_PANE_ID;
const source = "herdr:pi";

function herdrEnabled(): boolean {
  return HERDR_ENV === "1" && !!socketEndpoint && !!paneId;
}

function withSessionRef(
  params: Record<string, unknown>,
  ctx: ExtensionContext | undefined,
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
  state: "working" | "idle",
  ctx: ExtensionContext | undefined,
): void {
  if (!herdrEnabled()) return;
  const params = withSessionRef({
    pane_id: paneId,
    source,
    agent: "pi",
    state,
    seq: nextHerdrReportSequence(),
  }, ctx);
  if (!params) return;

  const request = {
    id: `herdr-busy:${Date.now()}:${Math.random().toString(36).slice(2)}`,
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
    // Never interrupt the parent turn if Herdr is unreachable.
  }
}

export default function (pi: ExtensionAPI) {
  if (!herdrEnabled()) {
    return;
  }

  let busyActive = false;
  let parentActive = false;
  let lastCtx: ExtensionContext | undefined;

  function remember(ctx: ExtensionContext | undefined): void {
    if (ctx) lastCtx = ctx;
  }

  pi.events.on("herdr:busy", (data: { active?: boolean } | undefined) => {
    busyActive = !!data?.active;
    if (busyActive) {
      reportAgent("working", lastCtx);
      return;
    }
    if (!parentActive) {
      reportAgent("idle", lastCtx);
    }
  });

  pi.on("session_start", (_event, ctx) => {
    remember(ctx);
    parentActive = ctx?.isIdle?.() === false;
    if (busyActive) {
      reportAgent("working", ctx);
    }
  });

  pi.on("agent_start", (_event, ctx) => {
    remember(ctx);
    parentActive = true;
  });

  pi.on("agent_settled", (_event, ctx) => {
    remember(ctx);
    if (ctx?.isIdle?.() === true) {
      parentActive = false;
    }
    // herdr-agent-state already queued idle; this seq must land after it.
    if (busyActive) {
      reportAgent("working", ctx);
    }
  });
}
