---
description: Review and improve a PRD request draft before conversion
---

You are executing `refine-request {argument}`.

Read `~/.config/opencode/skills/prd-workflow/SKILL.md` first and follow it exactly.

Rules:
- `{argument}` is required ID like `JP-001`.
- Read source `prds/{argument}.request.md`.
- Before advice, inspect project context (at minimum: CLAUDE.md + relevant feature files + request file) and summarize it.
- Evaluate against `assets/REFINE_CHECKLIST.md`.
- Return in this exact structure:
  1) Project context used
  2) Strengths
  3) Gaps
  4) Suggested edits by section (copy-paste text)
  5) Ready verdict: READY or NOT_READY
- Do not generate final PRD in this command.
