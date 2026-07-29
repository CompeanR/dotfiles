Use your own judgment and the main model for planning and coordination. For
anything you can scope into a clean subtask, deploy a subagent rather than
doing everything yourself in one long turn.

Give each subagent a clear goal, the relevant context, and what to bring
back. Don't have it invent the plan. Run independent pieces in parallel.

When they return, review the results before you merge anything. If
something's off, rewrite the brief and spin another — don't silently patch
over it yourself unless it's trivial.

## Subagents on a different model

Your built-in Agent/Task tool only spawns Claude models. When a task is
better suited to a different model — an existing explore/apply/design/verify
split already tuned for this in the user's Pi setup — use the
`herdr-subagent` skill instead: it drives a real Pi process through herdr on
the model/thinking level defined in `~/dotfiles/pi/settings.json`, using the
role contract in `~/dotfiles/pi/agents/work-<role>.md`. Don't duplicate that
mapping here; read it from those files.
