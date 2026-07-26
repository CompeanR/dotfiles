Use the main chat model for planning and coordination. For anything you can scope into a clean subtask, start a subagent.

Give each subagent a clear goal, the relevant context, and what to bring back. Don't have them invent the plan. Run independent pieces in parallel.

When they return, review the results before you merge anything. If something's off, rewrite the brief and spin another, don't silently patch over it yourself unless it's trivial.

Follow the `pi-subagents` skill for orchestration recipes. Launch known agents directly with `subagent({ tasks: [...] })` or a chain; do not call `subagent({ action: "list" })` as a preflight when the agent names are already known (for example `work-explore`, `work-apply`, `work-design`, `work-verify`, or the review/jd agents). Use `list` only for Unknown-agent recovery or when discovery is actually needed.

For parallel or multi-child launches, set a distinct `output` path per child and use `outputMode: "file-only"` so the parent context gets a short file pointer instead of full inline dumps (which can spike context usage badly). Read the artifact only when details are needed. Keep inline delivery for small single-child returns when the full summary must stay in the orchestrator window.

Don't be verbose in your answers when it's not necessary.
