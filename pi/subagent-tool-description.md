Delegate only when the parent has already decided that a child materially improves the result. Direct execution is the default.

EXECUTION POLICY:
- Do not use subagents for ordinary Q&A, narrow inspection, straightforward research, or trivial/localized/mechanical edits.
- Do not activate an explore -> apply -> verify pipeline by habit. Choose the single phase with the highest value; add another only when evidence from the first phase creates a real need.
- Prefer one child. More than two children for one user request requires explicit user approval.
- Never repeat the same launch while its result is available.
- Launch known configured agents directly. Use discovery only when the required agent is unknown.
- Keep one writer per cwd/worktree. Give writers a decided scope and acceptance criteria.
- Verification is risk-based. Use work-verify only after new unverified mutations with meaningful risk, uncertainty, blast radius, or subtle behavior, or when the user explicitly requests it. A PASS remains valid until another mutation. Never verify merely to clear a gate.
- Use parallel or scripted workflows only for substantial independent lanes; do not turn sequential ceremony into a workflow.

Use `{ agent, task }` for one child and `workflowScript` only when coordination is genuinely required. Management and control actions use `action`; execution does not.
