---
name: herdr-subagent
description: Deploy a Pi sub-agent on a non-Claude model (explore/apply/design/verify), driven through herdr, when a task benefits from a different model than the orchestrator. Use when the user asks for exploration, implementation, design, or verification work with a specific non-Anthropic model (composer, grok, gpt-5.6-sol), or says things like "throw a pi/composer/grok sub-agent at this".
---

# herdr-subagent

You (Claude Code) are the orchestrator. Your own Agent/Task tool only spawns
Claude models. When a task calls for a *different* model — the same
explore/apply/design/verify split already tuned in the user's Pi setup — use
this skill instead of the Task tool.

## Role -> model mapping

The mapping is **not duplicated here**. It lives in the user's Pi config,
which already works well and is the single source of truth:

- `~/dotfiles/pi/settings.json` -> `subagents.agentOverrides.work-<role>` for
  model + thinking level.
- `~/dotfiles/pi/agents/work-<role>.md` -> the role's contract (inputs,
  rules, required return shape) and its tool allowlist.

Four roles exist: `explore` (read-only investigation), `apply` (scoped
writer), `design` (read-only design proposal), `verify` (read-only
independent check). Read the relevant `work-<role>.md` before writing the
brief you hand it — its "Return" section tells you the shape to expect back.

## How to dispatch

Run the bundled script, which does the full herdr lifecycle for you (shared
`subagents`-tab pane, `agent start --kind pi` with the role's model/thinking/
tools, fire-and-forget prompt with resend recovery, decoupled `agent wait`,
full-transcript read, pane cleanup):

```
~/dotfiles/claude/skills/herdr-subagent/dispatch.sh <role> "<brief>" [options]
```

Options: `--cwd <path>`, `--pane <id>` (split from a specific pane instead of
the current one), `--timeout <ms>` (default 300000), `--name <name>`,
`--keep` (leave the pane open for inspection instead of closing it).

Write the brief the same way you'd write a Task-tool prompt: the delegated
goal, relevant context, constraints, and the exact return shape from the
role's `.md` file. These roles do not inherit project context or skills —
the brief must be self-contained.

## Running several in parallel

Do not chain `dispatch.sh` calls with the built-in `--wait` inside a single
background-job fan-out — see the reliability note in the script. Instead:

1. Call `dispatch.sh` for each role as separate background bash jobs.
2. Since `dispatch.sh` already decouples prompt from wait internally, running
   several of these concurrently is safe — each owns its own pane and its own
   `agent wait` call.
3. Collect each job's stdout (the role's report) once `wait` (shell builtin)
   returns.

## Known edge cases (already handled by the script, listed for awareness)

- `agent prompt --wait` has a fixed 5s "did state change yet" grace window
  that false-negatives under concurrent dispatch — the script never uses
  `--wait` on `prompt`, it waits separately via `agent wait`.
- Sub-agent panes land in a shared `subagents` tab (find-or-create, lock-
  guarded), never split into the orchestrator's own tab — keeps the
  orchestrator's window clean instead of accumulating panes in it.
- A freshly split pane can still be settling into its shell prompt when
  `agent start` fires, failing fast with `agent_pane_busy` instead of
  waiting for it. The script retries briefly instead of treating that as
  fatal.
- `agent start`'s readiness signal can fire before pi finishes loading
  skills/extensions (worse with `--tools`/`--append-system-prompt`), so a
  prompt sent immediately can land in the input line without the Enter
  registering — the text sits there unsent. If you naively resend, the
  resend's text *appends* to that still-unsent buffer, and both copies get
  submitted together as one concatenated message once Enter finally lands
  (not two separate turns — one dirty one). The script detects a flat
  `state_change_seq`, clears the input line with `ctrl+c` first (per pi's
  own "clear/exit" binding), and resends at most once.
- **`agent read` silently truncates long responses at a default ~80-line
  cap** (measured: bare read returned 78 lines where the full scrollback was
  95). No error — just a partial answer, which bit a long `design` report.
  Pass `--lines <N> --source recent-unwrapped` to lift it. The script does
  something better: it resolves the agent's session file via
  `agent get <name> | .agent_session.value` and reads pi's own JSONL
  transcript on disk, extracting the last assistant message's full text —
  clean prose with no startup banner, tool-call rendering, or box-drawing
  chrome. It falls back to `agent read --source recent-unwrapped --lines 2000`
  only if no session file is found.
- Per herdr's docs, full-screen TUI agents may render to the terminal's
  **alternate screen**, where scrollback doesn't persist at all — "if
  increasing `--lines` returns no additional response text, the pane is
  probably using the alternate screen." The docs' suggested workaround is to
  have the agent write its answer to a Markdown file and reply with the path,
  but that **cannot work for the read-only roles** (`explore`/`design`/
  `verify` have no write tool). Reading the session transcript is the only
  approach that works for every role.
- `pane move` on a pane with an in-flight `agent wait` ends the wait with
  `agent_not_running`. Don't rearrange herdr layout while a dispatched
  sub-agent is still working.
- Panes can go away between calls for reasons unrelated to your commands;
  if `agent read`/`agent wait` returns `agent_not_found`/`pane_not_found`,
  the run failed and should be retried, not silently ignored.
- Agent names must match `[a-z][a-z0-9_-]{0,31}` (herdr docs). The generated
  `work-<role>-<pid>` names comply; if you pass `--name`, keep it lowercase,
  ≤32 chars, and starting with a letter.
- The role's tool allowlist is read straight from the `.md` frontmatter and
  passed via `pi --tools`. **This does NOT make read-only roles safe**: the
  `explore`, `design`, and `verify` allowlists all include `bash`, and bash
  can write files, install things, and run setup commands. Their read-only
  nature is enforced only by prompt, not mechanically. This has already bitten
  once — an `explore` run investigating how to configure a tool ran
  `<tool> setup --help`, which actually executed setup and mutated
  `~/.claude/settings.json`. When dispatching a read-only role at anything
  involving installers, `setup`/`init` subcommands, or config writers, say so
  explicitly in the brief ("do not run any subcommand that can write, even
  with --help") and diff the relevant config before/after.
