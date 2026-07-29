import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

const extensionsDir = path.resolve(import.meta.dirname, "../extensions");

async function waitFor(predicate, message) {
  const deadline = Date.now() + 1_000;
  while (!predicate()) {
    if (Date.now() >= deadline) {
      assert.fail(message);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

test("an answered question settles the Herdr agent back to idle", async (t) => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "herdr-agent-lifecycle-"));
  const socketPath = path.join(tempDir, "herdr.sock");
  const sockets = new Set();
  const reports = [];
  let highestSequence = Number.NEGATIVE_INFINITY;
  let visibleState;

  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => {});

    let input = "";
    socket.on("data", (chunk) => {
      input += chunk.toString("utf8");
      for (;;) {
        const newline = input.indexOf("\n");
        if (newline < 0) break;

        const request = JSON.parse(input.slice(0, newline));
        input = input.slice(newline + 1);

        if (request.method === "pane.report_agent") {
          const { seq, state } = request.params;
          const accepted = seq > highestSequence;
          if (accepted) {
            highestSequence = seq;
            visibleState = state;
          }
          reports.push({ accepted, seq, state });
        }

        socket.write(`${JSON.stringify({ id: request.id, result: {} })}\n`);
      }
    });
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });

  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
    await rm(tempDir, { recursive: true, force: true });
  });

  process.env.HERDR_ENV = "1";
  process.env.HERDR_SOCKET_PATH = socketPath;
  process.env.HERDR_PANE_ID = "test:p1";

  const cacheBust = `?test=${Date.now()}-${Math.random()}`;
  const agentState = (
    await import(`${pathToFileURL(path.join(extensionsDir, "herdr-agent-state.ts")).href}${cacheBust}`)
  ).default;
  const attention = (
    await import(`${pathToFileURL(path.join(extensionsDir, "herdr-attention.ts")).href}${cacheBust}`)
  ).default;

  const lifecycleHandlers = new Map();
  const events = new EventEmitter();
  const pi = {
    events,
    on(name, handler) {
      const handlers = lifecycleHandlers.get(name) ?? [];
      handlers.push(handler);
      lifecycleHandlers.set(name, handlers);
    },
  };

  agentState(pi);
  attention(pi);

  let idle = true;
  const context = {
    hasUI: true,
    isIdle: () => idle,
    sessionManager: {
      getSessionFile: () => "/tmp/test-session.jsonl",
      getSessionId: () => "test-session",
    },
  };

  async function emit(name, event = {}) {
    for (const handler of lifecycleHandlers.get(name) ?? []) {
      await handler(event, context);
    }
  }

  await emit("session_start", { reason: "startup" });
  await waitFor(() => visibleState === "idle", "session start was not reported as idle");

  idle = false;
  await emit("agent_start");
  await waitFor(() => visibleState === "working", "agent start was not reported as working");

  const question = {
    toolCallId: "question-1",
    toolName: "ask_user_question",
    args: { question: "Continue?" },
    input: { question: "Continue?" },
  };
  await emit("tool_execution_start", question);
  await emit("tool_call", question);
  await waitFor(() => visibleState === "blocked", "question was not reported as blocked");

  await emit("tool_result", question);
  await emit("tool_execution_end", question);
  await waitFor(() => visibleState === "working", "answered question did not resume working");

  idle = true;
  const reportsBeforeSettled = reports.length;
  await emit("agent_settled");
  await waitFor(
    () => reports.slice(reportsBeforeSettled).some((report) => report.state === "idle"),
    "agent settlement did not produce an idle report",
  );

  assert.equal(
    visibleState,
    "idle",
    `Herdr remained ${visibleState}; reports: ${JSON.stringify(reports)}`,
  );
});
