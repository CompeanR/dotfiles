import assert from "node:assert/strict"
import test from "node:test"
import { fileURLToPath } from "node:url"
import { createJiti } from "../pi/npm/node_modules/jiti/lib/jiti.mjs"

const extensionPath = fileURLToPath(new URL("../pi/extensions/delegation-guard.ts", import.meta.url))
const delegationGuard = createJiti(import.meta.url)(extensionPath).default

function loadExtension() {
  const handlers = new Map()
  const entries = []
  const notices = []
  const renderers = new Map()

  delegationGuard({
    on(name, handler) {
      handlers.set(name, handler)
    },
    appendEntry(type, data) {
      entries.push({ type, data })
    },
    registerEntryRenderer(type, renderer) {
      renderers.set(type, renderer)
    },
  })

  return { handlers, entries, notices, renderers }
}

function uiContext(notices) {
  return {
    hasUI: true,
    ui: {
      notify(message, level) {
        notices.push({ message, level })
      },
    },
  }
}

test("substantial direct work injects and records one visible soft audit", () => {
  const harness = loadExtension()
  const before = harness.handlers.get("before_agent_start")({
    prompt: "Refactor the authentication architecture across multiple modules",
    systemPrompt: "base prompt",
  })

  assert.match(before.systemPrompt, /state `delegate` or `direct`/i)
  assert.equal("block" in before, false)

  harness.handlers.get("tool_result")({
    toolName: "read",
    toolCallId: "read-1",
    input: { path: "src/auth/session.ts" },
    isError: false,
  })
  harness.handlers.get("agent_end")({}, uiContext(harness.notices))
  harness.handlers.get("agent_end")({}, uiContext(harness.notices))

  assert.deepEqual(harness.entries, [{
    type: "delegation-guard-audit",
    data: {
      version: 1,
      outcome: "direct",
      delegationUsed: false,
      directExecutionUsed: true,
    },
  }])
  assert.deepEqual(harness.notices, [{ message: "Delegation audit: direct", level: "info" }])

  const renderer = harness.renderers.get("delegation-guard-audit")
  assert.equal(typeof renderer, "function")
  const component = renderer(harness.entries[0], {}, { fg: (_name, text) => text })
  assert.deepEqual(component.render(80), ["Delegation audit: direct"])
})

test("localized work receives no reminder or audit entry", () => {
  const harness = loadExtension()
  const before = harness.handlers.get("before_agent_start")({
    prompt: "Update one sentence in README.md",
    systemPrompt: "base prompt",
  })

  assert.equal(before, undefined)
  harness.handlers.get("agent_end")({}, uiContext(harness.notices))
  assert.deepEqual(harness.entries, [])
  assert.deepEqual(harness.notices, [])
})
