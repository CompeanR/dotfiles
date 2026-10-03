Remember, before starting a new project or implementing a new big feature we need to create the design on claude design

Don't overcomplicate solutions. Provide always the clearest one.
Avoid unnecessary code comments. Do not add a
`Co-authored-by` trailer to commits.

Every project lives in a GitHub repo (account CompeanR, private by default; create it if missing). Track issues, wayfinder maps and tickets as GitHub issues, never as local markdown.

In typescript always use 'public' keyword on public methods inside classes
Remember we have

work-explore
work-design
work-apply
work-verify

sub-agents. Use them when appropriate

In Workflow scripts, pass `model: 'claude-sonnet-5-5', effort: 'high'` on every agent() call, unless it uses agentType work-design.

When a step doesn't need my input, keep going. Put status notes in the
same message as your next action.
Stop and ask only when you can't continue without me, or before anything
destructive: deleting data, force-pushing, or changing anything outside
this repository.
