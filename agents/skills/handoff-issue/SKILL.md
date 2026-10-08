---
name: handoff-issue
description: File a task found here as an issue in another project, then start a fresh pi agent on it in that project's herdr workspace.
argument-hint: "<target project> <what to hand off>"
disable-model-invocation: true
---

Move a task that belongs to another project out of this context window. The issue is the hand-off: it carries everything the new agent knows, so it must stand alone.

1. **Check herdr.** `test "${HERDR_ENV:-}" = 1`. If it fails, say you are not inside herdr and stop.

2. **Resolve the target.** Map the project the user named to a git repo root, normally `~/Development/<name>`. If several match or none does, ask. Read its GitHub remote with `gh repo view --json nameWithOwner` from that folder.

3. **Summarize the source context.** Distill what this session knows about the task, written for an agent that has seen none of it:
   - **Found while**: the source repo, branch and what you were doing.
   - **Observed**: the exact symptom, with timestamps, run IDs, PR numbers, URLs, log lines and commands.
   - **Suspected cause**: your reasoning and how confident you are. Say what is fact and what is a guess.
   - **Already tried / ruled out**.
   - **Repro**, if you have one.
   - **Done when**: what the fix must achieve.

   Done when a stranger could start work from it without asking a question. Redact secrets and personal data.

4. **File the issue.** Search open issues first (`gh issue list -R <repo> --search "<keywords>"`). If one matches, comment the summary on it instead. Otherwise create the issue with `gh issue create -R <repo>`, using a short title and the summary as the body. Keep the issue number and URL.

5. **Name the tab and agent.** Tab label: `fix #<n>` plus 1–3 words (`feat` or `chore` when it isn't a bug). Agent name: `[a-z][a-z0-9_-]{0,31}`, unique in `herdr agent list`, e.g. `prm-fix-52`.

6. **Spawn.** Write the prompt to a temp file, then run:

   ```bash
   ~/.agents/skills/handoff-issue/spawn.sh <repo-dir> "<tab label>" <agent-name> <prompt-file>
   ```

   The prompt names the issue URL, tells the agent to read it with `gh issue view <n> --comments` and work it following the repo's own AGENTS.md, and lists any local-only evidence (screenshot paths, temp files) that can't live in the issue. The script first looks for the project's workspace in the herdr sidebar: its label matches the folder name (ignoring case), or one of its panes is already in that folder. It adds a new tab there, and only creates a workspace when none exists. It opens the tab without stealing focus, starts pi and sends the prompt. It does not wait for the agent to finish.

7. **Report.** Reply with the issue URL, the workspace/tab, and the agent name. Do not work on the task here.
