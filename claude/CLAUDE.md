Remember, before starting a new project or implementing a new big feature we need to create the design on claude design

Don't overcomplicate solutions. Provide always the clearest one.
Avoid unnecessary code comments. Do not add a
`Co-authored-by` trailer to commits.

Every project lives in a GitHub repo (account CompeanR, private by default; create it if missing). Track issues, wayfinder maps and tickets as GitHub issues, never as local markdown.

Write every PR body with the `pr` skill, including PRs opened by sub-agents and by other skills.

Load the `code-rules` skill before writing, designing or reviewing code, and add its red flags to every code review.

In typescript always use 'public' keyword on public methods inside classes
Remember we have

work-explore
work-design
work-apply
work-verify

sub-agents. Use them when appropriate

When a step doesn't need my input, keep going. Put status notes in the
same message as your next action.
Stop and ask only when you can't continue without me, or before anything
destructive: deleting data, force-pushing, or changing anything outside
this repository.

Run work-verify on sensitive tasks (git state, pushes, deletes, agents on my files).
Stop re-verifying once findings are no longer things normal use would hit, or after 3 rounds; list the rest for me.

I view your output from a different machine than the one you run on. Publish HTML reports and pages as Artifacts,
even when a skill says to write a local file and open it; never use a local file plus xdg-open.
