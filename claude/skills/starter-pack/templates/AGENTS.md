# {{PROJECT_NAME}}

{{PROJECT_SUMMARY}}

## Rules

- Main objective: small interfaces, deep modules. Read `docs/architecture.md` before adding or changing a module.
- The folder tree is organised by feature: one module per feature under `{{FEATURE_ROOT}}`, each with its narrow public interface.
- Name things with the terms in `CONTEXT.md`.
- When in doubt, pick the clearest solution.
- No code comments.
- New UI is designed in Claude Design first.
- Every PR follows `docs/pull-requests.md`. Write the body with the `pr` skill.
- Merge your own two-way PRs once CI and the review loop pass; one-way PRs wait for the owner. Rules in
  `docs/pull-requests.md`.
- Work on a branch. Pushing to `{{DEFAULT_BRANCH}}` is blocked by the pre-push hook.
- Commits: `type(scope): outcome`, 72 characters max, no Co-authored-by. The commit-msg hook checks it.
- Track work as GitHub issues.

## Commands

```
{{COMMANDS}}
```
