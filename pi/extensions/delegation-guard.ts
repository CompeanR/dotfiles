import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"
import {
  beginPrompt,
  createHarnessState,
  delegationReminder,
  evaluateSubagentCall,
  finishPromptAudit,
  recordSuccessfulTool,
  releaseFailedSubagentCall,
  reserveSubagentCall,
  snapshotHarnessState,
} from "./lib/delegation-policy.mjs"

const ENTRY_TYPE = "delegation-guard-state"
const AUDIT_ENTRY_TYPE = "delegation-guard-audit"

export default function delegationGuard(pi: ExtensionAPI): void {
  let state = createHarnessState()
  const pending = new Map<string, ReturnType<typeof evaluateSubagentCall>>()

  pi.on("session_start", (_event, ctx) => {
    const saved = [...ctx.sessionManager.getBranch()]
      .reverse()
      .find((entry) => entry.type === "custom" && entry.customType === ENTRY_TYPE)

    state = createHarnessState(saved?.type === "custom" ? saved.data : undefined)
    pending.clear()
  })

  pi.on("before_agent_start", (event) => {
    beginPrompt(state, event.prompt)
    const reminder = delegationReminder(state)
    if (reminder) return { systemPrompt: `${event.systemPrompt}\n\n${reminder}` }
  })

  pi.on("agent_end", (_event, ctx) => {
    const audit = finishPromptAudit(state)
    if (!audit) return
    pi.appendEntry(AUDIT_ENTRY_TYPE, audit)
    if (ctx.hasUI) ctx.ui.notify(`Delegation audit: ${audit.outcome}`, "info")
  })

  pi.registerEntryRenderer(AUDIT_ENTRY_TYPE, (entry, _options, theme) => {
    const audit = entry.data as { outcome?: string }
    return {
      render: () => [theme.fg("dim", `Delegation audit: ${audit.outcome ?? "unknown"}`)],
      invalidate() {},
    }
  })

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "subagent") return

    const decision = evaluateSubagentCall(state, event.input)
    if (decision.disposition === "block") {
      return { block: true, reason: decision.reason }
    }

    if (decision.disposition === "confirm") {
      if (!ctx.hasUI) return { block: true, reason: decision.reason }
      const approved = await ctx.ui.confirm(
        "Approve extra subagents?",
        `${decision.reason}\n\nAgents: ${decision.agents.join(", ") || "workflow-defined"}`,
      )
      if (!approved) return { block: true, reason: "Extra subagents declined by user." }
    }

    reserveSubagentCall(state, decision)
    pending.set(event.toolCallId, decision)
  })

  pi.on("tool_result", (event) => {
    const decision = pending.get(event.toolCallId)
    if (event.toolName === "subagent") pending.delete(event.toolCallId)

    if (event.isError) {
      if (decision) releaseFailedSubagentCall(state, decision)
      return
    }

    const changed = recordSuccessfulTool(state, event.toolName, event.input, decision)
    if (changed) pi.appendEntry(ENTRY_TYPE, snapshotHarnessState(state))
  })
}
