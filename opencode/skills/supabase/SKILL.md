---
name: supabase
description: >
    Supabase implementation rules for env contracts, hosted/local workflows, auth redirects, Edge Functions, and verification.
    Trigger: When adding or changing Supabase clients, auth flows, database workflows, migrations, Edge Functions, or hosted deployment scripts.
license: Apache-2.0
metadata:
    author: gentleman-programming
    version: "1.1"
---

## When to Use

- Wiring Supabase into mobile, web, or server apps
- Adding or changing hosted Supabase env vars, auth redirects, or Edge Function calls
- Creating migration, link, deploy, or verification scripts around the Supabase CLI
- Reviewing whether a new Supabase env var or workflow is real product scope or accidental complexity

## Critical Patterns

### Keep the Public Env Contract Small

- Default public client contract to the minimum required values: project URL and anon key.
- Add extra public env vars only when runtime behavior truly needs them.
- Do not add a separate public Edge Functions base URL unless the project actually uses a non-default gateway or proxy.
- When possible, derive the functions URL from the project URL as `<supabase-url>/functions/v1` instead of exposing another env var.

### Separate Operator Secrets from App Config

- Public app config belongs in app env examples/docs.
- Operator-only values such as `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, and hosted secret env files must stay out of repo-tracked app env contracts.
- If hosted function secrets are needed, keep them in an untracked env file used only by deploy scripts.

### Pin the Hosted Project Explicitly

- Commit the hosted project ref in `supabase/config.toml` or equivalent checked-in config.
- Make scripts target the pinned ref instead of relying on whichever project the CLI was last linked to.
- Add a read-only status command that confirms auth state and the resolved hosted project before migrations or deploys.

### Prefer Non-Interactive CLI Workflows

- Use `npx supabase ...` when the CLI is a repo dependency instead of assuming a global install.
- Wrap `supabase link`, `supabase db push`, and function deploys in repo scripts so CI and humans run the same flow.
- Prefer dry-run commands before write commands for hosted migrations.

### Auth Redirects Must Match End-to-End

- If passwordless or OAuth returns into the app, keep the app scheme, redirect env, and Supabase Auth dashboard redirect list aligned.
- Verify the callback route/parser with real or scripted checks after auth changes.
- Treat redirect/session exchange as part of the contract, not incidental UI glue.

### Be Intentional About Expo Session Persistence

- In Expo native apps, do not assume `persistSession: true` with a secure storage adapter is always safe; `supabase-js` persists a full serialized session blob, which can become too large for comfortable SecureStore usage.
- If the session blob grows large or Expo warns about payload size, prefer minimal token persistence (token pair only) and restore session explicitly on boot.
- When using custom minimal persistence, prove three things separately: sign-in stores usable tokens, sign-out clears them, and malformed/partial persisted payloads fail closed without restoring a session.
- If auth restore is custom, keep router decisions behind auth bootstrap completion so sign-in UI does not flash before a valid persisted session is restored.

### Verify Local and Hosted Separately

- Local verification should cover typecheck, RLS/policy behavior, and Edge Function handler behavior.
- Hosted verification should cover CLI auth, pinned project linkage, migration readiness, function deploy readiness, and app runtime config alignment.
- After contract changes, rerun the full relevant verification chain instead of assuming docs-only edits are safe.

## Decision Tree

```
Need Supabase in app runtime?                 -> Add only project URL + anon key by default
Thinking about a new public env var?          -> Add it only if runtime cannot derive or avoid it
Need hosted DB/function operations?           -> Use pinned project config + repo scripts + npx supabase
Need app auth callback?                       -> Align app scheme, redirect env, and Supabase dashboard URLs
Changing migrations/functions/auth contract?  -> Run local + hosted verification commands
Expo app auth persistence getting complex?    -> Prefer minimal token persistence + fail-closed boot verification over default full-session storage
```

## Code Examples

### Minimal public client env

```env
EXPO_PUBLIC_SUPABASE_URL=https://your-project-ref.supabase.co
EXPO_PUBLIC_SUPABASE_ANON_KEY=your-anon-key
EXPO_PUBLIC_SUPABASE_AUTH_REDIRECT_URL=your-app://auth/callback
```

### Derive the functions URL instead of exposing another public env

```ts
function normalizeBaseUrl(value: string) {
    return value.replace(/\/+$/, "");
}

function resolveFunctionsUrl(supabaseUrl: string) {
    return `${normalizeBaseUrl(supabaseUrl)}/functions/v1`;
}
```

### Hosted script pattern

```bash
npx supabase status
npx supabase link --project-ref "$SUPABASE_PROJECT_REF"
SUPABASE_DB_PUSH_DRY_RUN=1 bash ./supabase/scripts/apply-hosted-migrations.sh
bash ./supabase/scripts/deploy-hosted-functions.sh
```

## Commands

```bash
npm run typecheck
npm run mobile:verify
npm run mobile:verify:auth-redirect
npm run supabase:cloud:link-status
npm run supabase:cloud:migrate:dry-run
npm run supabase:cloud:migrate
npm run supabase:cloud:functions:deploy
npm run supabase:verify
npm run verify:phase7
```

## Resources

- **Supabase config**: keep hosted project pinning and operator workflows under `supabase/`
- **App env contract**: keep public mobile/web env examples close to the app that consumes them
