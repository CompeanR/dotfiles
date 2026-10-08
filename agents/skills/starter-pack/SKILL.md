---
name: starter-pack
description: "Set up a repo with my conventions: architecture docs, git hooks, lint and format, CI and the PR process."
disable-model-invocation: true
---

Sets up a new or existing repo in two PRs: guardrails first, agent docs second. Templates are in `templates/`, per-stack
wiring and placeholder values are in `stacks.md`. Both live next to this file.

## Facts

- Private repos on the free plan cannot enforce branch protection. The hooks are the enforcement; CI is advisory.
- The harness may suggest a `Co-Authored-By` trailer. The commit-msg hook rejects it and the user's rule wins.
- Commit format: `type(scope): outcome`, 72 characters max. Types: `feat|fix|refactor|test|docs|style|chore|ci|build|perf`.
  The scope allows `[a-z0-9_/-]`.
- Every stack exposes `make setup|fmt|check|brief`, plus `lint` and `test` where the stack has them. Hooks and CI call
  `make check`.
- List files with `git ls-files`, since `ls` may be aliased.
- CI runs on the user's mac-mini, a self-hosted runner, with `runs-on: [self-hosted, mac-mini]`. The Actions billing
  limit blocks GitHub-hosted runners: their jobs fail before the first step, with the reason only in the run's
  annotations. A personal account cannot share a runner between repos, so every repo registers its own. One runner
  runs one job at a time.
- A re-run reuses the workflow file of the commit it first ran on. After a `ci.yml` change, open PRs need a rebase.

## 1. Inspect

- Stack: detect it from manifests: `go.mod`; `package.json` with `pnpm-lock.yaml` or a `packageManager` pnpm field;
  `bun.lock` and `package-lock.json` in different folders (Bun + npm packages); `CMakeLists.txt` that calls
  `idf_component_register` or has an `sdkconfig` or `app_main`. With no code, ask the user for the stack.
- Default branch: `git symbolic-ref --short refs/remotes/origin/HEAD`, else `main`.
- Remote: `gh repo view --json nameWithOwner`. When missing, create it: `gh repo create CompeanR/<directory name>
  --private --source . --remote origin`. Commit existing files as `chore(repo): initial commit` when the repo has no
  commit, then `git push -u origin <default>`.
- Done when stack, default branch and `origin` are known, and `origin/<default>` exists.

## 2. Branch

- Stop and ask when the tree has uncommitted changes.
- `git switch <default> && git pull --ff-only`, then `git switch -c chore/starter-pack`.
- Done when `git branch --show-current` prints `chore/starter-pack` and `git status --short` is empty.

## 3. Guardrails PR

- Copy from `templates/` with `cp -pr`: `.githooks/`, `scripts/pr-brief.sh`, `scripts/one-way.sh`, `.github/pull_request_template.md`,
  `.github/workflows/ci.yml`, `docs/pull-requests.md`, `.editorconfig`, `.gitattributes`. Keep the executable bits.
- Add the stack wiring from `stacks.md`: Makefile, tool configs, the `.gitignore` entries and the CI setup step. When a
  file exists, merge into it.
- Fill every placeholder of the copied files from the `stacks.md` table.
- Run `make setup`, then `make fmt`, then `make check` (stack equivalent when the stack has no Makefile). `git add` new
  source files first when the stack's `make` reads `git ls-files`.
- Done when all of these hold:
  - `grep -rE '\{\{[A-Z_]+\}\}' .githooks scripts .github docs .editorconfig .gitattributes Makefile` prints nothing.
  - `make check` passes.
  - The hook trial passes, with `git commit --allow-empty -m <subject>` on this branch:
    - `bad subject` is rejected.
    - A message with a `Co-authored-by:` trailer is rejected.
    - `chore(repo): hook trial` passes, then `git reset --soft HEAD~1` (the soft reset keeps the formatted files and
      staged work).
    - `git push --dry-run origin HEAD:<default>` is blocked.

## 4. Commit, push, CI

- When `make fmt` changed tracked source files, commit those files alone first as `style(repo): apply the formatter`.
- `git add` the copied files, the stack wiring, `.gitignore` and the lock file `make setup` created; check `git status
  --short` shows only those. Commit as `chore(repo): guard commits, pushes and PR size`.
- Create the labels the CI reads, when missing: `gh label create one-way --color B60205 --description "Owner merges after
  review; agents stop at the review loop"` and `gh label create scope-exception --color D93F0B --description "Owner-approved
  one-way PR over the 1,500 hand-line limit"`.
- Register the repo's CI runner on the mac-mini, unless `gh api repos/CompeanR/<repo>/actions/runners --jq
  '.runners[].name'` already lists `mac-mini-<repo>`. Run this on the mac-mini (`hostname -s` prints `Javiers-Mac-mini`;
  from another machine, over `ssh mac-mini`). Run it as one script: a multi-line paste into the user's terminal
  wraps and breaks the URL.

  ```bash
  set -e
  repo=<repo>
  v=$(gh api repos/actions/runner/releases/latest --jq '.tag_name | ltrimstr("v")')
  mkdir -p ~/actions-runner/$repo && cd ~/actions-runner/$repo
  curl -sfLo runner.tar.gz "https://github.com/actions/runner/releases/download/v$v/actions-runner-osx-arm64-$v.tar.gz"
  tar xzf runner.tar.gz && rm runner.tar.gz
  token=$(gh api -X POST repos/CompeanR/$repo/actions/runners/registration-token --jq .token)
  ./config.sh --unattended --url https://github.com/CompeanR/$repo --token "$token" --name mac-mini-$repo --labels mac-mini
  ./svc.sh install && ./svc.sh start
  ```

  Done when `gh api repos/CompeanR/<repo>/actions/runners --jq '.runners[] | "\(.name) \(.status)"'` prints
  `mac-mini-<repo> online`. When `config.sh` says the folder is already configured but GitHub lists no runner,
  run `./svc.sh uninstall` and `./config.sh remove --token "$token"` in it, then register again.
- `git push -u origin chore/starter-pack`, then open the PR against the default branch. Write the body with the `pr` skill.
  The PR touches `.github/` and `.githooks/`, so it is one-way: the owner merges it.
- `gh pr checks --watch`.
- Done when CI is green. When an action tag fails to resolve, pin an existing release tag (see `stacks.md`), commit
  `ci(repo): pin <action> to <tag>` and push again.

## 5. Agent docs PR

- Branch `docs/agent-rules` from the default branch after step 4 merges, or stacked on `chore/starter-pack` while it is
  open.
- Copy `AGENTS.md`, `CLAUDE.md`, `CONTEXT.md` and `docs/architecture.md` from `templates/`. Fill them from the real
  codebase (`git ls-files`), the issues (`gh issue list`) and the README, with the `stacks.md` values for commands and
  architecture. Never invent a term, folder or command.
  - When a source is missing (no README, no issues), ask the user for the project summary and the domain words. Write
    only what the code or the user states.
  - `AGENTS.md`: project name and summary, the feature root, the default branch, and one line per Makefile target that
    exists, with the descriptions and list rules in `stacks.md`.
  - `CONTEXT.md`: the domain words the code, issues and README use, grouped by area. Add `_Avoid_` only when the code or
    issues show a competing word. Delete the second area when the code has one group.
  - `docs/architecture.md`: one module per feature, each with its narrow public interface. Fill the tree from
    `git ls-files`, the public surface from the entry points, the rules, readability limits and dependency examples
    from the stack's architecture values. Fill the `{{...}}` prompts inside the principles sections; keep their prose.
- Run `make fmt` so the formatter accepts the new files.
- Commit `docs(repo): add agent rules and architecture`, push, open the PR with the `pr` skill, watch CI.
- Done when `grep -rE '\{\{' AGENTS.md CLAUDE.md CONTEXT.md docs/architecture.md` prints nothing, every section has real
  content, the docs name only targets that exist in the Makefile, and `scripts/pr-brief.sh <base>` reports "within the
  500-line target", where `<base>` is `origin/<default>`, or `chore/starter-pack` when the PR is stacked.

## 6. Report

- List the PR links and the runner (`mac-mini-<repo>` in `~/actions-runner/<repo>`).
- List what is not enforced: no branch protection, hooks bypassed by `--no-verify`, CI advisory, and anything skipped
  (no tests, no linter, no build in CI).
