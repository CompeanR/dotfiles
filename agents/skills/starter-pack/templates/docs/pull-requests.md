# Pull requests

One person reviews in the web UI, so a PR is sized by what is read.

## Budget (`make brief`; CI runs it from the base commit)
- One concern. If the sentence needs "also", split before opening.
- Hand lines (code, tests, docs, config, deletions): 500 or fewer.
  Above 500 CI warns and the body says why; above 1,500 CI fails.
- Hand files: 50 or fewer. Generated files and pure renames: not gated.
- Deleted files count: skim the list and the tests removed.
- Over 1,500: a two-way PR only warns (it merges after the review
  loop and is sampled later). A one-way PR fails; its body asks for
  `scope-exception` and the owner adds it.

## Body
Write it with the `pr` skill; `.github/pull_request_template.md` is
that skill's template, copied verbatim: the one-sentence concern, a
Summary visual, before/after Evidence, Merge Danger (door and blast
radius) and the Claude Design check.

## Commits
1. Formatter and move changes first; regenerated outputs last.
2. Fold fixes: `git commit --fixup <sha>`, then
   `GIT_SEQUENCE_EDITOR=: git rebase --autosquash origin/{{DEFAULT_BRANCH}}`.
3. No Co-authored-by. Messages: `type(scope): outcome`, 72 chars max.
   The PR title follows the same rule: it becomes the squash commit.

## Doors
Three voices name the door; the strictest wins, so a voice can only
make a PR more one-way, never less.
1. **The body**: the `Door:` line the `pr` skill writes from the
   whole diff.
2. **The files**, mechanically: `scripts/one-way.sh` lists them
   (dependencies, `.github/`, `.githooks/`, the `Makefile`), and CI's
   Door job adds the `one-way` label. CI runs the base branch's copy,
   so a PR can't loosen the rule that judges it.
3. **The reviewer**: each `work-verify` round reads the diff and
   names the door with its reason. One-way is what a revert can't
   undo: a stored or wire shape the old code can't read, code that
   pushes, force-pushes or deletes data, branches or files, anything
   that loses data or reaches the outside world.

The files catch what a persuasive body would hide; the reviewer
catches what no file name shows. Everything else is two-way.

## Merging
Branch from `origin/{{DEFAULT_BRANCH}}`, never from another open PR.
Work that needs an unmerged PR waits for it; two-way PRs merge fast,
so the wait is short.

**Two-way: the agent merges** once all of these hold:
1. CI is green.
2. The review loop is done: `work-verify` reviews, the findings are
   fixed, and it reviews again until what is left is nothing normal
   use would hit. The PR body lists those leftovers.
3. The repo's verify step passes, when it has one.

Then `gh pr merge <n> --squash --delete-branch`, after checking the
base is `{{DEFAULT_BRANCH}}`.

**One-way: the owner merges.** Add the `one-way` label and stop at
the review loop.

## Review routine
Two-way PRs are reviewed after they land, by sampling: read
`git log origin/{{DEFAULT_BRANCH}}` since the last read, open the PRs
that look off, revert what is wrong. A mistake seen twice becomes a
lint rule, a test or a line in `AGENTS.md`, not a comment on one PR.

One-way PRs are reviewed before the merge:
1. Read the body.
2. Read the diff; leave generated files collapsed.
3. To try it, check the PR out in its worktree and run it.
4. After fixes, use "Changes since your last review".

## After a merge
`git worktree remove ../{{REPO_NAME}}-wt/<name>`, `git branch -D <branch>`,
`git fetch --prune origin`.
