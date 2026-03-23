---
name: prd-workflow
description: >
  PRD request-to-document workflow automation with project-local numbering.
  Trigger: When user asks `new-request`, `new-prd <ID>`, or to refine/convert PRD drafts.
metadata:
  owner: compean
  version: "1.1"
---

## Purpose
Automate PRD flow per project:
1) `new-request` creates next request draft file
2) refine request in chat
3) `new-prd <ID>` converts request into final PRD

## Project-local state
Store state only in repo:
- `prds/.meta.json`
- `prds/<PREFIX>-NNN.request.md`
- `prds/<PREFIX>-NNN.prd.md`
- backups: `prds/_history/`

`prds/.meta.json` schema:
```json
{
  "project_prefix": "JP",
  "next_number": 1
}
```


## Mandatory project grounding (before advice/refinement/conversion)
Before suggesting enhancements, ALWAYS inspect and summarize project context from repo files.
Minimum grounding pass:
1) Read `CLAUDE.md` (or project overview doc)
2) Read `prds/<ID>.request.md` (for refine/new-prd)
3) Read 2-4 relevant code/docs files tied to requested feature
4) Check current capabilities/constraints from existing implementation

Output must include a short **Project context used** section first.
If context is insufficient, state what is missing and ask for file/path.
Never give enhancement advice without this grounding step.

## Command semantics
### new-request
- Ensure `prds/` exists.
- Load `prds/.meta.json`; if missing ask for prefix and create with `next_number: 1`.
- Create next file `<PREFIX>-NNN.request.md` (3-digit zero-pad) from request template.
- Increment `next_number` in meta.
- Return created path.


### refine-request <ID>
- Require explicit ID like `JP-001`.
- Read `prds/<ID>.request.md`.
- Run mandatory project grounding first.
- Evaluate with `assets/REFINE_CHECKLIST.md` + observed project context.
- Return:
  - Project context used
  - strengths
  - gaps
  - suggested edits by section
  - verdict `READY` or `NOT_READY`
- Do not convert to PRD in this command.

### new-prd <ID>
- Require explicit ID like `JP-001`.
- Read `prds/<ID>.request.md`.
- Run mandatory project grounding first.
- Convert using PRD template + conversion rules aligned to observed project context.
- Write `prds/<ID>.prd.md`.
- If target exists: backup to `prds/_history/<ID>.prd.<YYYYmmdd-HHMMSS>.md` before overwrite.

## Conversion contract (strict)
- Exact heading titles/order from assets/PRD_TEMPLATE.md
- No invented facts
- Missing data => `[TBD: specific question]`
- Conflicts => section `## 12) Open Questions`
- Keep concise and testable FR/NFR/AC

## Edit loop
- Patch by section refs, e.g. `update 5.FR-2`, `update 7.Primary KPI`.
- Modify only requested sections unless user asks broad rewrite.

## Files
- Request template: `assets/REQUEST_TEMPLATE.md`
- PRD template: `assets/PRD_TEMPLATE.md`
- Conversion rules: `assets/CONVERSION_RULES.md`
- Refinement checklist: `assets/REFINE_CHECKLIST.md`
