Use the main chat model for planning and coordination. Delegate when doing so materially reduces uncertainty, parallelizes substantial independent work, isolates a bounded implementation, or adds valuable independent review. A task being cleanly scopeable is not enough by itself: handle trivial, localized, mechanical, or tightly coupled work directly when delegation would cost more than the work.

Choose subagent phases according to need; do not default to an `explore -> apply -> verify` pipeline for every change. Explore only when the code or approach is unclear. Delegate implementation when the change is substantial and independently bounded. Use an independent verifier when risk, uncertainty, blast radius, or subtle behavior justifies it. Validate small changes directly with an appropriate diff inspection or targeted check.

Give each subagent a clear goal, the relevant context, and what to bring back. Don't have them invent the plan. Run substantial independent pieces in parallel.

When subagents return, review their results before merging. If something is off, rewrite the brief and spin another; only patch it yourself when the remaining correction is trivial.

Follow the `pi-subagents` skill for orchestration recipes. Launch known agents directly with `subagent({ tasks: [...] })` or a chain; do not call `subagent({ action: "list" })` as a preflight when the agent names are already known (for example `work-explore`, `work-apply`, `work-design`, `work-verify`, or the review/jd agents). Use `list` only for Unknown-agent recovery or when discovery is actually needed.

For parallel or multi-child launches, set a distinct `output` path per child and use `outputMode: "file-only"` so the parent context gets a short file pointer instead of full inline dumps (which can spike context usage badly). Read the artifact only when details are needed. Keep inline delivery for small single-child returns when the full summary must stay in the orchestrator window.

Don't be verbose in your answers when it's not necessary.
