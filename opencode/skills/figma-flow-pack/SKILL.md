---
name: figma-flow-pack
description: >
  Workflow for handling exported Figma flow image packs delivered as zip files.
  Trigger: When the user provides a zip of flow screenshots/exports and wants the agent to extract, inspect, group, and use them as a UI reference source.
license: Apache-2.0
metadata:
  author: gentleman-programming
  version: "1.0"
---

## When to Use

Use this skill when:
- The user shares a zip containing exported Figma screens or flow screenshots
- Figma MCP is unavailable, rate-limited, or insufficient for detailed UI inspection
- The agent needs a repeatable way to extract flow packs and build a quick index
- The user wants UI analysis or implementation based on exported flow images

## Critical Patterns

### Treat Exports As Reference, Not Literal UI

- Use the screenshots to recover layout rhythm, hierarchy, spacing, card sequencing, and component patterns.
- Do not copy domain wording, exact content, or branded product metaphors from the source app.
- Preserve the user's adaptation rule for the target product context.

### Build A Fast Local Reference Index

- Extract the zip to a temp or user-approved working folder.
- Build a manifest grouped by folder/flow so the agent can inspect representative screens quickly.
- Prefer a small representative sample first, then inspect more images only where needed.

### Start With Flow-Level Analysis

- Identify each flow's repeated structure before discussing polish.
- Focus first on:
  - screen hierarchy
  - hero card usage
  - CTA placement
  - density level
  - nav/tab patterns
  - palette and surface treatment
- Only then map those patterns into the target app.

### Use The Helper Script

```bash
python3 /home/compean/.config/opencode/skills/figma-flow-pack/assets/extract_flow_pack.py \
  --zip "/path/to/flow-pack.zip" \
  --output "/tmp/flow-pack"
```

- The script extracts the archive and creates `manifest.json` and `manifest.txt` for quick navigation.
- After extraction, use direct file reads on representative images instead of manually browsing every archive entry.

## Decision Tree

```
User provided Figma zip export?          -> Load this skill
Figma MCP is rate-limited/unavailable?   -> Use the zip pack as primary UI reference
Need quick structure only?               -> Inspect manifest + 3-6 representative screens
Need high-fidelity polish guidance?      -> Inspect all key screens in the relevant flow folder
Repeated zip-pack tasks across sessions? -> Reuse this script/workflow
```

## Code Examples

### Extract and index a flow pack

```bash
python3 /home/compean/.config/opencode/skills/figma-flow-pack/assets/extract_flow_pack.py \
  --zip "/home/compean/Downloads/gentleman-approacher.zip" \
  --output "/tmp/gentleman-approacher-flows"
```

### Review the generated manifest

```bash
python3 /home/compean/.config/opencode/skills/figma-flow-pack/assets/extract_flow_pack.py \
  --zip "/home/compean/Downloads/gentleman-approacher.zip" \
  --output "/tmp/gentleman-approacher-flows"

# Then inspect /tmp/gentleman-approacher-flows/manifest.txt
```

## Commands

```bash
python3 /home/compean/.config/opencode/skills/figma-flow-pack/assets/extract_flow_pack.py --zip "/path/to/pack.zip" --output "/tmp/flow-pack"  # extract and index flow pack
ls "/tmp/flow-pack"                                                                                                              # inspect extracted flow folders
```

## Resources

- **Templates**: See [assets/](assets/) for the zip extraction/indexing helper.
