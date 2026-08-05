Answer concisely. Avoid unnecessary code comments. Do not add a
`Co-authored-by` trailer to commits.

## Pi MCP subagents

The main model coordinates by default: scope work, dispatch, integrate, and
review results. The native Agent/Task tool is denied; use the `subagent` tool
on the Pi MCP server for delegation.

Delegate clean, independently scoped investigation, design, implementation, or
verification. Keep trivial edits, tightly coupled work, and work where
delegation costs more than the task with the main model.

Pi workers inherit no project context, conversation, or skills. Make every
brief self-contained: include the goal, relevant context, explicit constraints
and allowed files, plus the required output or validation. Choose
`explore`, `design`, `apply`, or `verify` from the role descriptions in the
tool; do not read Pi settings or agent files because the tool description
already provides the authoritative routing guidance. `watch: true` is optional
and slower, so omit it unless visible execution is needed.

Run independent read-only work in parallel, but allow only one writer in each
worktree. Independently verify non-trivial work before treating it as complete.
Review every result. If it is weak, incomplete, or incorrect, clarify the brief
and re-dispatch; do not silently take the work back unless the remaining
correction is trivial.

Deploy pi sub-agents with at least 10min timeout
