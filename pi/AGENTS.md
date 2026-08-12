Default to direct execution by the main chat model. Before loading the `pi-subagents` skill or calling `subagent`, decide whether delegation materially reduces uncertainty, parallelizes substantial independent work, isolates a substantial bounded implementation, or adds valuable independent review. For substantial work, briefly state `delegate` or `direct` with the reason before acting; the harness audits the observed execution path without blocking direct work. A task being cleanly scopeable is not enough. Handle Q&A, inspection, research with a narrow answer, and trivial, localized, mechanical, or tightly coupled edits directly.

Do not default to an `explore -> apply -> verify` pipeline. Choose at most the one phase that adds the most value; add another only when new evidence justifies it. More than two children for one user request requires explicit user approval. Never launch the same brief twice while its result is available.

Verification is risk-based, not ceremonial. Launch `work-verify` only after new unverified mutations when risk, uncertainty, blast radius, or subtle behavior justifies independent context, or when the user explicitly requests verification. A prior PASS remains valid until another mutation; never launch a verifier to "clear a gate" when nothing changed. Validate low-risk changes directly with diff inspection and focused checks.

Once delegation has been chosen, follow the `pi-subagents` skill only for execution mechanics. Give each child a decided goal, relevant context, allowed scope, acceptance criteria, and expected return; do not ask it to invent the plan. Launch known agents directly without a `list` preflight. Use `list` only for unknown-agent recovery or real discovery.

Keep one writer for a cwd/worktree. Review returned work before using it. If a child result is materially wrong, revise the brief before retrying; patch only trivial residual corrections directly.

For parallel or multi-child launches, set a distinct `output` path per child and use `outputMode: "file-only"` so the parent context gets a short file pointer instead of full inline dumps (which can spike context usage badly). Read the artifact only when details are needed. Keep inline delivery for small single-child returns when the full summary must stay in the orchestrator window.

Don't be verbose in your answers when it's not necessary.
