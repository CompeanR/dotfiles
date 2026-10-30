# Errors and special cases

Chapters 6.8 and 10. Throwing errors is easy; handling them is hard. Every exception a module can throw is part of its interface and makes it shallower. **Reduce the number of places where errors must be handled.** Apply these techniques in order.

## 1. Define errors out of existence

Change the operation's definition so the error case becomes normal behavior.

- "Delete the variable" fails if it's missing; "make sure the variable doesn't exist" can't fail.
- `substring` that returns the overlap of the requested range never needs an out-of-bounds error (as `slice` does in JS and Python).
- Deleting an open file can mark it for deletion instead of failing.

```ts
// Error case every caller must handle
public removeTag(tag: string): void {
  if (!this.tags.has(tag)) throw new Error(`No tag ${tag}`);
  this.tags.delete(tag);
}

// Defined away: after the call, the tag is absent
public removeTag(tag: string): void {
  this.tags.delete(tag);
}
```

Rejecting everything suspicious is not safety. The extra code callers write to avoid or ignore errors creates its own bugs. The simplest software has the fewest bugs.

The same idea applies to special cases in ordinary code: design the normal case so edge cases fall out of it. Represent "no selection" as an empty selection (start === end) rather than a `hasSelection` flag checked everywhere.

## 2. Mask errors low

Handle the condition inside a low-level module so nothing above sees it: retry a dropped request inside the client, not at every call site. Masking pulls complexity downward.

## 3. Aggregate errors high

Let many errors travel to one handler instead of catching each one where it happens.

- Request-driven systems (HTTP servers, job runners, CLIs, UI actions): one handler at the top of the request loop turns any request-aborting error into the response. Route handlers and helpers just throw.
- The code that detects the error writes the human-readable message into the error; the top handler only formats and sends it. Neither knows the other's details.
- Define one base error class for "abort this request" (subclasses for specific conditions), clearly separate from errors that are fatal to the process.
- New code that throws the same way plugs in with no handler changes.

```ts
// One boundary for every route
app.onError((err, c) =>
  err instanceof RequestError
    ? c.json({ error: err.message }, err.status)
    : c.json({ error: 'Internal error' }, 500));

// Deep inside any handler
public getIntParameter(name: string): number {
  const raw = this.params.get(name);
  if (raw === undefined) throw new RequestError(`parameter '${name}' not present`, 400);
  ...
}
```

Promoting rare small errors into a larger one that already has a recovery path is a form of aggregation; it also means the recovery path runs often enough to be trusted.

## 4. Just crash

For errors that are rare and can't sensibly be handled (internal inconsistency, out of memory, a missing required env var at startup), print a clear diagnostic and abort. Don't sprinkle recovery code for them. Whether a given error qualifies depends on the application.

## Taking it too far

Only define away or mask what callers truly don't need to know. If callers need the information to work correctly (a network module that silently drops failures leaves callers unable to be robust), expose it. Never catch an error and return a success value.
