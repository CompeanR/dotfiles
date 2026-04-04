---
name: typescript
description: >
  TypeScript project conventions for formatting, config, and verification.
  Trigger: When working in TypeScript projects or adding/updating TS tooling/config.
license: Apache-2.0
metadata:
  author: gentleman-programming
  version: "1.0"
---

## When to Use

- Editing or creating TypeScript/TSX files
- Adding repo-level TS tooling such as Prettier, tsconfig, or typecheck scripts
- Normalizing formatting conventions in TypeScript projects

## Critical Patterns

- Default Prettier config for TypeScript projects:

```json
{
  "singleQuote": true,
  "trailingComma": "all",
  "printWidth": 125,
  "tabWidth": 4,
  "useTabs": false,
  "semi": true
}
```

- Prefer a root `.prettierrc.json` using that config unless the repo already has an explicit conflicting style.
- Add `format` and `format:check` scripts when introducing Prettier.
- Run `npm run typecheck` after meaningful TypeScript changes when available.
- Public class methods should explicitly declare `public` instead of relying on TypeScript's default visibility.
- Preserve existing project conventions if they are already intentionally different; otherwise use the config above as the default.

## Code Examples

```json
{
  "scripts": {
    "format": "prettier --write .",
    "format:check": "prettier --check .",
    "typecheck": "tsc --noEmit"
  },
  "devDependencies": {
    "prettier": "^3.6.2",
    "typescript": "^5.0.0"
  }
}
```

## Commands

```bash
npm install -D prettier
npm run format
npm run format:check
npm run typecheck
```
