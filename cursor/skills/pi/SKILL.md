---
name: pi
description: >-
  Operates Pi from Cursor through mcp_pi_* tools: files/shell when native
  Cursor tools fail or the workspace is none, Engram memory, Pi subagents
  (work-explore, work-apply, work-verify), and intercom to other Pi sessions.
  Use when the user mentions Pi, Engram, pi-subagents, or intercom; when
  Cursor tools return unavailable; or when work should run through Pi agents.
---

# Pi from Cursor

Pi is the MCP server prefixed `mcp_pi_`. Prefer Cursor native tools while they work. Switch to Pi for the rest of the turn when they fail, when the workspace is none, or when the user wants Pi memory, subagents, or intercom.

## Fallback

If Cursor `Read` / `Write` / `Glob` / `Grep` / `Shell` / `Task` return "Tool not available in this environment", stop retrying them. Use the Pi equivalents with **absolute paths**.

| Need | Tool |
|---|---|
| read | `mcp_pi_read` |
| write (create/overwrite) | `mcp_pi_write` |
| edit | `mcp_pi_edit` (`edits: [{oldText, newText}]`) |
| shell | `mcp_pi_bash` |
| search | `mcp_pi_bash` with `rg` / `find` (no Pi glob/grep) |
| todos | `mcp_pi_todo` |
| ask user | `mcp_pi_ask_user_question` |

If `mcp_pi_*` tools are missing, say Pi MCP is not connected. Do not invent a local `pi` CLI substitute.

## Memory

Engram is `http://127.0.0.1:7437`. If it is down, continue without looping on `mem_*`.

- Start of a repo task: `mcp_pi_mem_session_start` with `cwd` and a short `id`
- Recall: `mcp_pi_mem_search`, `mcp_pi_mem_context`
- Keep: `mcp_pi_mem_save` for durable facts only

## Subagents

Follow `/home/compean/dotfiles/pi/subagent-tool-description.md` for execution policy. From Cursor, this is the launch shape:

```
mcp_pi_subagent({
  async: false,
  workflowScript: 'return runs.run("main", { agent: "work-explore", task: "Decided goal, scope, acceptance, return shape" })'
})
```

Rules:

- Omit `action` on execution calls. `action` is management only; never put the task there.
- Launch a known agent: `work-explore`, `work-design`, `work-apply`, `work-verify`, `review-risk`, `review-readability`, `review-reliability`, `review-resilience`. Do not guess names like `explore` or `general`.
- Never set `model` or `thinking` in the tool args or inside `runs.run`.
- Give a decided brief. Do not ask the child to invent the plan.
- One writer per cwd. Prefer one child; more than two needs explicit user approval.
- Do not dump the parent transcript into the child.

Cursor MCP kills blocking calls around **5 minutes**. Use `async: false` only when the child should finish this turn and the work is short. For live SSH, verify, or anything that may run long:

```
mcp_pi_subagent({
  async: true,
  workflowScript: 'return runs.run("main", { agent: "work-verify", task: "..." })'
})
```

Then `mcp_pi_subagent_wait` (or end the turn and wait for the completion notice). Do not relaunch a child whose result is already available.

Do not use Cursor `Task` as a substitute for Pi subagents when this skill is active.

## Intercom

Other live Pi sessions (TUI, Herdr panes) are reached with `mcp_pi_intercom`, not subagents.

- `action: "list"` or `"list-cwd"` first
- `send` is fire-and-forget; `ask` waits for a reply
- `reply` answers an inbound ask; do not reconstruct raw IDs unless you must

## Web

`mcp_pi_web_search`, `mcp_pi_fetch_content`, `mcp_pi_source_check`, `mcp_pi_get_search_content`. Use these when the user wants Pi-backed research or Cursor web tools are unavailable.

## Do not confuse

`mcp_pi_mcp` is Pi's gateway to **other** MCP servers (usually empty here). It is not a catalog of `mcp_pi_*` tools and cannot recover a missing Pi server.
