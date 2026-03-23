---
description: Convert request file into PRD file with strict template/order
---

You are executing `new-prd {argument}`.

Read `~/.config/opencode/skills/prd-workflow/SKILL.md` first and follow it exactly.

Rules:
- `{argument}` is required ID like `JP-001`.
- Source: `prds/{argument}.request.md`.
- Before conversion, inspect project context (at minimum: CLAUDE.md + relevant feature files + request file) and align PRD language to existing project reality.
- Target: `prds/{argument}.prd.md`.
- If target exists, backup to `prds/_history/{argument}.prd.<YYYYmmdd-HHMMSS>.md` before overwrite.
- Use template from `assets/PRD_TEMPLATE.md` with exact headings/order.
- No invented facts; missing => `[TBD: specific question]`; conflicts => `## 12) Open Questions`.

Return target path and count of `[TBD: ...]` markers.
