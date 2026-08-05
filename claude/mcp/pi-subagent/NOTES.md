# pi-subagent — notes

Reference material for humans. Nothing here is loaded into an agent's context:
the MCP tool description is generated from `pi/settings.json` and
`pi/agents/work-<role>.md` at server startup, so a caller needs no file reads
before dispatching.

## Layout

- `server.mjs` — MCP stdio server. The default path. Runs `pi -p` as a plain
  subprocess and returns its stdout.
- `dispatch.sh` — the herdr pane lifecycle. Only used for `watch: true`.

Role → model/thinking comes from `pi/settings.json`
(`subagents.agentOverrides.work-<role>`); the role contract and tool allowlist
come from `pi/agents/work-<role>.md`. Both stay the single source of truth —
neither is duplicated here or in the server.

## Registration

`~/.claude.json` is not tracked in dotfiles, and `install.sh` does not manage
Claude config, so on a fresh machine re-register with:

```
claude mcp add pi --scope user -- node ~/dotfiles/claude/mcp/pi-subagent/server.mjs
```

Verify with `claude mcp list` (should report `pi: … ✔ Connected`).

## Why print mode is the default

This started as a skill that drove pi's TUI through a herdr pane. That works,
but almost every failure mode below is an artifact of puppeting an interactive
terminal rather than of running an agent. `pi -p` honors `--tools` and
`--append-system-prompt <file>`, which is everything the role contract needs,
so the pane is optional — and skipping it deletes the whole class of problems.

Measured on this machine, "reply with exactly: OK":

| path | wall clock | pi CPU |
| --- | --- | --- |
| `subagent` print mode (default) | **14.8s** | 9.4s |
| `subagent` `watch: true` | 24.5s | — |
| `dispatch.sh` pane path, pre-fix | 22.9s | — |
| `pi -p`, all packages | 16.5s | 9.8s |
| `pi -p`, only the provider extension | 13.0s | 6.8s |
| `pi` bare startup floor | 1.7s | 1.5s |

Wall clock is noisy — model latency swings it by 10s+ between identical runs
(one `pi -p` run measured 29s). CPU time is the stable signal. Conclusions:

- Print mode is the win, because it skips pi's TUI cold start (~15s until pi
  can accept input) along with pane setup and the whole swallowed-prompt
  problem.
- The pane path did **not** get faster (22.9s → 24.5s, within noise). It got
  *correct*: no more mandatory resend, no more 16s of fixed sleep, and the
  double-submit risk is off the happy path. Its floor is pi TUI boot, which
  cannot be avoided while keeping the run visible.
- Startup trimming is worth ~3s of CPU, and `--no-extensions` is how you'd get
  it — but that also removes the `cursor/*` and `openai-codex/*` providers
  (they come from `pi-cursor-sdk`) plus `mem_search` / `web_search` /
  `fetch_content`, which are in the role allowlists. So extensions stay on.
  The server passes only `--no-skills --no-prompt-templates
  --no-context-files`, which is safe: the roles already set
  `inheritSkills: false` and `inheritProjectContext: false`, so loading them
  would contradict the role contract anyway.

## Read-only roles are not mechanically read-only

`explore`, `design`, and `verify` are read-only *by prompt only*. Their tool
allowlists all include `bash`, and bash can write files, install things, and
run setup commands. This has already bitten once: an `explore` run
investigating how to configure a tool ran `<tool> setup --help`, which
actually executed setup and mutated `~/.claude/settings.json`.

### `--tools` does not restrict cursor/* roles at all

Worse than the bash caveat, and measured directly. Asked to report their own
tool surface and then to attempt a write to a scratch path, the two provider
families behaved completely differently:

| role | provider | tools reported | write attempt |
| --- | --- | --- | --- |
| `explore` | `cursor/composer-2.5` | **23**, incl. `Write`, `StrReplace`, `Delete`, `Task` | succeeded via **`Write`** |
| `verify` | `openai-codex/gpt-5.6-sol` | **exactly** `read, grep, find, bash` | succeeded via **`bash`** |

Both files landed on disk. So:

- For **`cursor/*`** roles (`explore`, `apply`) the `--tools` allowlist is
  close to meaningless for safety. This is documented upstream, not a bug in
  this server — `pi-cursor-sdk`'s README (line 452) and
  `docs/cursor-tool-surfaces.md` (line 13) both state that pi's `--no-tools`,
  `--tools` and `--exclude-tools` "do not disable this Cursor-native surface":
  they gate only pi's own bridge tools (the `pi__*` names), while Cursor SDK
  host tools stay callable and are owned by Cursor. Note `Task` is in that
  set, so a cursor-backed role can spawn its own sub-agents even though every
  role contract says not to.
- For **`openai-codex/*`** roles (`design`, `verify`) the allowlist *is*
  applied exactly — but `bash` is in it, so writes remain trivial.

**Consequence for the fail-closed guard in `server.mjs`:** it is still worth
having, because it keeps the declared allowlist honest and stops an accidental
*widening* of the openai-codex roles. But do not read it as a security
boundary. It cannot restrict a cursor-backed role, and it does not stop bash.
Real enforcement has to come from outside pi — a sandbox, a read-only mount,
or a throwaway git worktree.

When dispatching a read-only role at anything involving installers,
`setup`/`init` subcommands, or config writers, say so explicitly in the brief
("do not run any subcommand that can write, even with `--help`") and diff the
relevant config before and after. The tool description carries a short version
of this warning.

## TUI edge cases — only relevant to `watch: true`

All of these are handled in `dispatch.sh`. They do not apply to the default
print-mode path.

- **A prompt sent before pi is ready is swallowed entirely, not delayed.**
  This is the single most important thing to know about the pane path, and it
  is easy to misdiagnose. Measured directly by sampling `agent get` once a
  second:

  - Prompt sent ~1s after `agent start`: `state_change_seq` never moved and
    `agent_status` stayed `idle` — observed flat for the full 42s of
    sampling. The prompt was gone, not queued.
  - Prompt sent 15s after `agent start`: registered in **3s**, status went to
    `working`. A single send, no retry needed.

  So the old `sleep 8` → resend → `sleep 8` sequence was not a rare recovery
  path. The resend was the thing making *every* dispatch work at all, and the
  fixed sleeps cost 16s whether needed or not. Widening the window is the
  wrong fix and actively worse (a 30s poll made a trivial run take 44.9s,
  double the 22.9s baseline) because waiting longer on a swallowed prompt
  accomplishes nothing.

  The fix is short adaptive rounds: send, poll ~6s, and if nothing registered,
  clear the input and send again — converging as soon as pi is ready. A
  trivial run now registers on attempt 2 and finishes in ~23s.

  **The status check in `wait_for_registration` is a safety guard, not an
  optimization.** If a prompt *did* register and the agent is already
  `working`, sending `ctrl+c` would interrupt a live run rather than clear a
  stuck input line. Registration is therefore "seq moved OR status left
  `idle`".

  Readiness is deliberately *not* detected by scraping the pane for a UI
  marker: pi's frame does appear around t=4s, but that is TUI chrome, and per
  the alternate-screen note below, pane content is not a dependable signal.
- **Unsent-Enter concatenation.** `agent start`'s readiness signal can fire
  before pi finishes loading skills/extensions (worse with `--tools` /
  `--append-system-prompt`), so a prompt sent immediately lands in the input
  line without the Enter registering — the text just sits there. Naively
  resending *appends* to the still-unsent buffer, and both copies submit
  together as one concatenated message once Enter finally lands. Not two
  turns — one dirty one. The script clears the line with `ctrl+c` (pi's own
  clear/exit binding) before resending, and resends at most once.
- **`agent prompt --wait` has a fixed 5s grace window** that false-negatives
  under concurrent dispatch. Never use `--wait` on `prompt`; wait separately
  via `agent wait`.
- **`agent read` silently truncates at ~80 lines.** No error, just a partial
  answer — measured 78 lines returned where the full scrollback was 95. This
  bit a long `design` report. `--lines N --source recent-unwrapped` lifts the
  cap but still returns TUI chrome (startup banner, skill list, tool-call
  rendering, box drawing). The script instead resolves the session file via
  `agent get <name> | .agent_session.value` and reads pi's own JSONL
  transcript from disk, extracting the last assistant message as clean prose.
  Pane read is the fallback.
- **Alternate screen.** Per herdr's docs, full-screen TUI agents may render to
  the terminal's alternate screen, where scrollback doesn't persist at all —
  "if increasing `--lines` returns no additional response text, the pane is
  probably using the alternate screen." The docs suggest having the agent
  write its answer to a Markdown file and reply with the path, but that
  **cannot work for the read-only roles**, which have no write tool. Reading
  the session transcript is the only approach that works for every role.
- **`agent_pane_busy`.** A freshly split pane can still be settling into its
  shell prompt when `agent start` fires, which fails fast rather than waiting.
  The script retries for ~10s in 0.5s steps.
- **`pane move` kills an in-flight `agent wait`** with `agent_not_running`.
  Don't rearrange herdr layout while a dispatched sub-agent is working.
- **Panes can vanish** between calls for unrelated reasons. If
  `agent read`/`agent wait` returns `agent_not_found` / `pane_not_found`, the
  run failed and should be retried, not silently ignored.
- **Agent names** must match `[a-z][a-z0-9_-]{0,31}`. The generated
  `work-<role>-<pid>` names comply; a custom `--name` must too.
- Sub-agent panes land in a shared `subagents` tab (find-or-create, guarded by
  `flock` against two concurrent dispatches both creating one), never split
  into the orchestrator's own tab.

## Server behavior worth knowing

- Concurrent `tools/call` requests genuinely run in parallel — each spawns its
  own `pi` process and replies by request id. Verified: two calls on different
  providers completed in 20.0s total when each takes ~20s alone, returning out
  of order.
- stdin EOF does not immediately exit. A sub-agent run outlives the request
  that started it, so the server drains in-flight work first; otherwise a
  client disconnect (or a piped test) silently loses the result.
- The brief is passed to `pi` as a positional argument via `spawn` with an
  argument array — no shell, so no injection concern. A brief that *starts*
  with `-` could in principle be misparsed as a flag; briefs don't normally
  look like that.
- There is no concurrency cap in the server. `pi/settings.json` sets
  `subagents.globalConcurrencyLimit: 5`, but that governs pi's own subagent
  spawning, not ours.
