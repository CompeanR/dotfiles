Use direct execution for small, localized, mechanical, or tightly coupled work. For substantial debugging, implementation, or review, actively consider one focused child when it can own a meaningful lane; delegation does not require parallel work or exceptional risk.

EXECUTION POLICY:
- Do not use subagents for ordinary Q&A, narrow inspection, straightforward research, or trivial/localized/mechanical edits.
- Do not activate an explore -> apply -> verify pipeline by habit. Choose the single phase with the highest value; add another only when evidence from the first phase creates a real need.
- Prefer one child. More than two children for one user request requires explicit user approval.
- Never repeat the same launch while its result is available.
- Launch known configured agents directly. Use discovery only when the required agent is unknown.
- Keep one writer per cwd/worktree. Give writers a decided scope and acceptance criteria.
- Verification is risk-based. Use work-verify only after new unverified mutations with meaningful risk, uncertainty, blast radius, or subtle behavior, or when the user explicitly requests it. A PASS remains valid until another mutation. Never verify merely to clear a gate.
- Use parallel or scripted workflows only for substantial independent lanes; do not turn sequential ceremony into a workflow.

EXECUTION CONTRACT FOR THIS INSTALLED RUNTIME:
- Call the `subagent` tool directly. Do not search for it through the generic `mcp` gateway.
- All model-facing execution uses `workflowScript`, including one child. For a foreground child whose result is needed this turn, use:
  `subagent({ workflowScript: 'return runs.run("main", { agent: "work-explore", task: "Your decided task and acceptance criteria" })', async: false })`
- Omit `action` on execution calls. `action` is management/control only. Do not put task text in `action`.
- Launch a known configured agent such as `work-explore`, `work-design`, `work-apply`, or `work-verify`; use `action: "list"` only when the needed agent is unknown.
- From a Cursor parent, never set `model` or `thinking` in the tool arguments or inside `runs.run`; let the configured agent resolve them. This keeps children on their tested provider and avoids Cursor tool-resume loops.
