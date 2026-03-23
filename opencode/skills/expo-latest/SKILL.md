---
name: expo-latest
description: >
    Expo managed-workflow rules for staying on the latest stable SDK and verifying app health after changes.
    Trigger: When working on Expo or Expo Router apps, especially when scaffolding, upgrading SDKs, changing Expo packages, or validating that the app still builds.
license: Apache-2.0
metadata:
    author: gentleman-programming
    version: "1.2"
---

## When to Use

Use this skill when:

- Creating or modifying an Expo app
- Upgrading Expo SDK, React Native, React, or Expo Router
- Adding Expo-managed packages or config plugins
- Verifying that an Expo project still runs after dependency or config changes

## Critical Patterns

### Latest Stable SDK First

- Default to the latest stable Expo SDK unless the user explicitly pins a different version.
- On iOS, remember Expo Go only supports the latest SDK, so stale SDKs frequently cause false runtime/debugging noise.
- Treat `expo`, `react`, `react-native`, `expo-router`, and Expo support packages as a compatibility set.

### Use Expo-Aware Installs

```bash
# Good: lets Expo choose compatible versions
npx expo install expo-router expo-status-bar react-native-safe-area-context react-native-screens expo-linking expo-constants

# Avoid: manually pinning Expo-managed package versions with plain npm unless necessary
npm install expo-router expo-status-bar
```

- Prefer `npx expo install` for Expo-managed packages.
- If upgrading SDK, update the SDK first, then install compatible support packages.
- If peer conflicts happen, check `react`, `react-native`, and `@types/react` together.

### Monorepo And Workspace Hygiene

- In npm workspaces, keep a root `typecheck` or `verify` script that runs shared packages before the Expo app, so app imports are validated in dependency order.
- If the Expo app depends on local packages, prefer workspace-level verification commands over app-only checks when changing shared types, config, or runtime contracts.
- Keep React dedupe safeguards at the workspace root with `overrides` when needed; Expo runtime issues often come from workspace drift, not the mobile app alone.

### Router And Generated Types

- If using Expo Router typed routes, keep `experiments.typedRoutes` enabled in app config and include `.expo/types/**/*.ts` plus `expo-env.d.ts` in the app TS config.
- Treat `expo-env.d.ts` and generated route types as part of the app contract; missing TS includes can look like router bugs when they are really config drift.
- After router or app-config changes, re-run typecheck before debugging runtime navigation issues.

### Verification Is Required

After Expo dependency/config changes, run all of these:

```bash
npx expo install --check
npx expo-doctor@latest
npm run typecheck
npx expo export --platform ios --platform android
npx expo start --clear
```

- `expo install --check` confirms package compatibility for the current SDK.
- `expo-doctor` checks app config and dependency health.
- `typecheck` should run from the repo level in monorepos so shared packages and app imports are checked together.
- `expo export` proves Metro can bundle the app for native targets.
- `expo start --clear` is the required post-upgrade runtime smoke step before trusting Expo Go results.

### Add Product Verification Scripts

- Generic Expo checks are necessary but not sufficient; add lightweight `tsx` or Node verification scripts for product-critical flows that do not need a simulator.
- Good candidates: deep-link/auth redirect parsing, provider boot/session restore, mocked runtime state flows, and request/handler contract checks for backend boundaries.
- Wire these into `package.json` as explicit `verify:*` scripts and, in monorepos, aggregate them behind a root `verify` command.
- Prefer deterministic assertions over UI automation for these checks so they stay fast enough to run after config and dependency changes.

### Single React Copy Rule

- After Expo upgrades, confirm the app resolves to one `react` and one `react-dom` version.
- In npm workspaces, use root `overrides` if nested packages pull a second React line.
- If runtime shows `Invalid hook call`, suspect duplicate React before blaming component code.

### Runtime Validation

- If the project uses Expo Go, confirm the SDK matches the installed Expo Go version.
- If a runtime error mentions missing native modules (for example `PlatformConstants`), suspect SDK/package mismatch, stale Metro cache, or opening the project in the wrong client binary.
- After an SDK upgrade, restart Metro cleanly before debugging runtime issues.

### Auth Bootstrap And Storage

- In Expo auth flows, treat cold-boot restore as a first-class state machine; do not let the router make signed-out decisions before auth bootstrap settles.
- If you implement custom auth restore, keep `isBooting` true until persisted-token restore and the first post-restore `getSession()` check complete.
- Guard against premature auth lifecycle events such as an initial empty session event flipping boot state false before restore has finished.
- Auth routes should self-guard too: while booting, render nothing or a neutral placeholder; if already signed in, redirect away immediately.
- Prefer simple boot gating before experimenting with splash-screen orchestration; incorrect splash gating can blank the app even when auth logic is correct.

### Platform-Specific Storage And Cache Hygiene

- For platform-specific persistence, use platform-resolved modules: `.native.ts` for `expo-secure-store`, `.web.ts` for `localStorage`, and plain `.ts` for Node/test fallback.
- Do not rely on brittle runtime detection if Metro can resolve the right file per platform.
- If native behavior still looks wrong after a storage/module fix, retry with `npx expo start --clear`; stale Metro cache can hide platform-resolution changes.
- When debugging native persistence, verify behavior with a full Expo Go kill/reopen, not just a same-process reopen from Expo Go home.

## Decision Tree

```
Working on an Expo app?                    -> Load this skill
User pinned a specific SDK?                -> Respect it, do not auto-upgrade past it
Project is on old SDK with Expo Go issue?  -> Upgrade to latest stable SDK first
Using Expo Router typed routes?            -> Confirm app config + TS includes for generated Expo types
Changed Expo deps/config?                  -> Run compatibility + doctor + workspace typecheck + export verification
Project has critical app flows?            -> Add or run product-specific verify scripts, not just Expo smoke checks
Runtime still fails after upgrade?         -> Clear Metro, confirm correct client, then inspect native-module mismatch
Invalid hook call appears?                 -> Check for multiple React copies and dedupe with overrides/reinstall
Custom auth restore added?                 -> Gate routing until restore settles; self-guard auth routes; prefer platform-specific storage modules
```

## Code Examples

### SDK upgrade flow

```bash
npx expo install expo@^54.0.0
npx expo install expo-router expo-status-bar react-native-safe-area-context react-native-screens expo-linking expo-constants
npx expo install --check
npx expo-doctor@latest
npm run typecheck
npx expo export --platform ios --platform android
```

### Monorepo verify wiring

```json
{
    "scripts": {
        "typecheck": "npm --workspace @acme/shared run typecheck && npm --workspace @acme/mobile run typecheck",
        "mobile:verify": "npm --workspace @acme/mobile run verify",
        "verify": "npm run typecheck && npm run mobile:verify"
    },
    "overrides": {
        "react": "19.1.0",
        "react-dom": "19.1.0"
    }
}
```

### Product verification wiring

```json
{
    "scripts": {
        "verify:auth-redirect": "tsx scripts/verify-auth-redirect.ts",
        "verify:runtime": "tsx scripts/verify-runtime.tsx",
        "verify": "npm run verify:auth-redirect && npm run verify:runtime"
    }
}
```

### Clean restart after upgrade

```bash
npx expo start --clear
```

## Commands

```bash
npx expo install --check                  # verify Expo package compatibility
npx expo-doctor@latest                    # validate Expo config and dependency health
npm run typecheck                         # verify workspace TypeScript and router types
npx expo export --platform ios --platform android  # verify native bundles can be produced
npx expo start --clear                    # restart Metro with cleared cache
npm ls react react-dom react-native       # inspect for duplicate React/runtime versions
npm run verify                            # run app-specific product verification scripts when present
```

## Resources

- **Documentation**: Use Expo SDK release notes and upgrade walkthrough for the currently targeted stable SDK.
