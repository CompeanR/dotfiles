# Pull requests

One person reviews in the web UI, so a PR is sized by what is read.

## Budget (`make brief`; CI runs it from the base commit)
- One concern. If the sentence needs "also", split before opening.
- Hand lines (code, tests, docs, config, deletions): 500 or fewer.
  Above 500 CI warns and the body says why; above 1,500 CI fails.
- Hand files: 50 or fewer. Generated files and pure renames: not gated.
- Deleted files count: skim the list and the tests removed.
- Over 1,500: the body asks for `scope-exception`; the owner adds it.

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

## Review routine
1. Read the body.
2. Read the diff; leave generated files collapsed.
3. To try it, check the PR out in its worktree and run it.
4. After fixes, use "Changes since your last review".

## After a merge
`git worktree remove ../{{REPO_NAME}}-wt/<name>`, `git branch -D <branch>`,
`git fetch --prune origin`. Stacked base squash-merged:
`git merge --no-ff origin/{{DEFAULT_BRANCH}}`.
