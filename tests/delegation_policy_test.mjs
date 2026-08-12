import assert from "node:assert/strict"
import test from "node:test"
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
} from "../pi/extensions/lib/delegation-policy.mjs"

function stateFor(prompt = "Implement the requested change") {
  const state = createHarnessState()
  beginPrompt(state, prompt)
  return state
}

function launch(state, input) {
  const decision = evaluateSubagentCall(state, input)
  if (decision.disposition === "allow") reserveSubagentCall(state, decision)
  return decision
}

test("allows one useful child without ceremony", () => {
  const decision = launch(stateFor(), { agent: "work-explore", task: "Inspect the unclear parser seam" })
  assert.equal(decision.disposition, "allow")
  assert.equal(decision.childCount, 1)
})

test("requires approval before a request exceeds two children", () => {
  const state = stateFor()
  assert.equal(launch(state, { agent: "work-explore", task: "Inspect A" }).disposition, "allow")
  assert.equal(launch(state, { agent: "work-design", task: "Design B" }).disposition, "allow")
  const third = launch(state, { agent: "work-apply", task: "Implement C" })
  assert.equal(third.disposition, "confirm")
  assert.match(third.reason, /launch 3 children/i)
})

test("explicit orchestration request permits a larger fanout", () => {
  const state = stateFor("Use three subagents in parallel to compare these implementations")
  const decision = launch(state, {
    workflowScript: "await runs.all([{agent:'work-explore'},{agent:'work-design'},{agent:'review-risk'}])",
  })
  assert.equal(decision.disposition, "allow")
  assert.equal(decision.childCount, 3)
})

test("mentioning AGENTS.md does not count as requesting agents", () => {
  const state = stateFor("Update AGENTS.md with the new policy")
  const decision = launch(state, {
    workflowScript: "await runs.all([{agent:'work-explore'},{agent:'work-design'},{agent:'review-risk'}])",
  })
  assert.equal(decision.disposition, "confirm")
})

test("blocks verify when nothing changed", () => {
  const decision = launch(stateFor(), { agent: "work-verify", task: "Verify the completed work" })
  assert.equal(decision.disposition, "block")
  assert.match(decision.reason, /no unverified mutations/i)
})

test("blocks ceremonial verify after a low-risk edit", () => {
  const state = stateFor()
  recordSuccessfulTool(state, "edit", {
    path: "README.md",
    edits: [{ oldText: "old", newText: "new" }],
  })
  const decision = launch(state, { agent: "work-verify", task: "Check the wording change" })
  assert.equal(decision.disposition, "block")
  assert.match(decision.reason, /low-risk/i)
})

test("allows one risk-based verify and blocks a no-op rerun after PASS", () => {
  const state = stateFor()
  recordSuccessfulTool(state, "edit", {
    path: "src/auth/session.ts",
    edits: [{ oldText: "old", newText: "new" }],
  })

  const first = launch(state, { agent: "work-verify", task: "Verify session behavior" })
  assert.equal(first.disposition, "allow")
  assert.deepEqual(first.riskReasons, ["high-risk path"])
  recordSuccessfulTool(state, "subagent", {}, first)

  const second = evaluateSubagentCall(state, {
    agent: "work-verify",
    task: "Run another independent verification so the gate clears",
  })
  assert.equal(second.disposition, "block")
  assert.match(second.reason, /no unverified mutations/i)
})

test("a delegated writer creates verification risk", () => {
  const state = stateFor()
  const apply = launch(state, { agent: "work-apply", task: "Implement the parser change" })
  assert.equal(apply.disposition, "allow")
  recordSuccessfulTool(state, "subagent", {}, apply)

  const verify = launch(state, { agent: "work-verify", task: "Verify parser behavior" })
  assert.equal(verify.disposition, "allow")
  assert.ok(verify.riskReasons.includes("delegated writer"))
})

test("blocks a duplicate launch but permits retry after failure", () => {
  const state = stateFor()
  const input = { agent: "work-explore", task: "Inspect the parser" }
  const first = launch(state, input)
  assert.equal(first.disposition, "allow")
  assert.equal(evaluateSubagentCall(state, input).disposition, "block")

  releaseFailedSubagentCall(state, first)
  assert.equal(evaluateSubagentCall(state, input).disposition, "allow")
})

test("mutating bash creates uncertain verification risk", () => {
  const state = stateFor()
  assert.equal(recordSuccessfulTool(state, "bash", { command: "git apply /tmp/change.patch" }), true)
  const decision = launch(state, { agent: "work-verify", task: "Verify resulting behavior" })
  assert.equal(decision.disposition, "allow")
  assert.ok(decision.riskReasons.includes("uncertain shell mutation"))
})

test("persistent snapshot retains mutation and PASS state", () => {
  const state = stateFor()
  recordSuccessfulTool(state, "write", { path: "config/security.json", content: "{}" })
  const verify = launch(state, { agent: "work-verify", task: "Verify configuration" })
  recordSuccessfulTool(state, "subagent", {}, verify)

  const restored = createHarnessState(snapshotHarnessState(state))
  beginPrompt(restored, "Continue")
  const rerun = evaluateSubagentCall(restored, { agent: "work-verify", task: "Verify again" })
  assert.equal(rerun.disposition, "block")
  assert.match(rerun.reason, /no unverified mutations/i)
})

test("explicit user verification bypasses mutation requirement", () => {
  const state = stateFor("Please independently verify the existing implementation")
  const decision = launch(state, { agent: "work-verify", task: "Review existing behavior" })
  assert.equal(decision.disposition, "allow")
})

test("substantial work receives a soft delegation reminder", () => {
  const state = stateFor("Refactor the authentication architecture across multiple modules")
  assert.match(delegationReminder(state), /state `delegate` or `direct`/i)
})

test("localized edits and read-only questions do not receive reminders", () => {
  assert.equal(delegationReminder(stateFor("Update AGENTS.md with one sentence")), undefined)
  assert.equal(delegationReminder(stateFor("Explain how the authentication module works")), undefined)
})

test("audit reports direct execution without blocking it", () => {
  const state = stateFor("Fix the security behavior across multiple modules")
  assert.equal(recordSuccessfulTool(state, "read", { path: "src/auth.ts" }), false)
  const audit = finishPromptAudit(state)
  assert.deepEqual(audit, {
    version: 1,
    outcome: "direct",
    delegationUsed: false,
    directExecutionUsed: true,
  })
  assert.equal(finishPromptAudit(state), undefined)
})

test("audit reports successful delegation", () => {
  const state = stateFor("Refactor the parser architecture")
  const decision = launch(state, { agent: "work-explore", task: "Inspect the parser seams" })
  recordSuccessfulTool(state, "subagent", {}, decision)
  assert.equal(finishPromptAudit(state).outcome, "delegated")
})

test("audit reports mixed parent and delegated execution", () => {
  const state = stateFor("Integrate the new API across multiple services")
  recordSuccessfulTool(state, "edit", {
    path: "src/api.ts",
    edits: [{ oldText: "old", newText: "new" }],
  })
  const decision = launch(state, { agent: "review-risk", task: "Review the API risk" })
  recordSuccessfulTool(state, "subagent", {}, decision)
  assert.equal(finishPromptAudit(state).outcome, "mixed")
})

test("failed delegation without direct work audits as no execution", () => {
  const state = stateFor("Migrate the database architecture")
  const decision = launch(state, { agent: "work-explore", task: "Inspect the migration" })
  releaseFailedSubagentCall(state, decision)
  const audit = finishPromptAudit(state)
  assert.equal(audit.outcome, "no-execution")
  assert.equal(JSON.stringify(audit).includes(state.prompt.text), false)
})
