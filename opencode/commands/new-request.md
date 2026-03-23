---
description: Create next PRD request draft in prds/ using project-local prefix/counter
---

You are executing `new-request`.

Read `~/.config/opencode/skills/prd-workflow/SKILL.md` first and follow it exactly.

Do now:
1. Ensure `prds/` exists in current project.
2. Read `prds/.meta.json`.
3. If missing, ask user for project prefix (e.g. JP), then create:
   `{ "project_prefix": "<PREFIX>", "next_number": 1 }`
4. Create next request file `prds/<PREFIX>-NNN.request.md` from `assets/REQUEST_TEMPLATE.md`.
5. Increment `next_number` in `prds/.meta.json`.
6. Return created path only.
