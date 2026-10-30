# Comments

Chapters 12, 13, 15, 16. Comments capture what the designer knew that the code can't express. Without them, an abstraction is only its signature, which is too little to use correctly. **Comments describe what isn't obvious from the code.**

## What to write

- **Interface comment** before a class, function or method when its signature leaves out something callers need:
  - for a class, what each instance represents, what it offers, and its limits (e.g. not safe for concurrent use);
  - for a function, its behavior as callers see it, every constraint on arguments, the return value, side effects, errors thrown, and preconditions.
  A caller should never need to read the body to call it.
- **Field and variable comments** where the name and type leave gaps: units, inclusive or exclusive bounds, what `null` or `undefined` means, who owns cleanup, invariants. Describe what the variable represents (nouns), not how code changes it (verbs).
- **Implementation comments** inside long functions: what each major block does and why, never how. One line before a block or a nontrivial loop ("Each iteration extracts one request and appends its response"). Explain tricky code and bug-fix workarounds, linking the issue.
- **Cross-module decisions**: document them where developers will go anyway (beside the enum everyone must extend, listing the other places to update). If there's no such place, use a `designNotes` section and point to it with "See X in designNotes".

## What not to write

- Comments that repeat the code. The test: could someone who has never seen this code write the comment just by reading the line beside it? If yes, delete it or replace it with information the code lacks.
- Comments that reuse the words of the name they describe (`// Get normalized resource names` above `getNormalizedResourceNames`).
- Implementation details in interface comments. Put them inside the body.
- Explanations of a called function at the call site; that belongs in the callee's interface comment.
- Rationale that lives only in a commit message. If future developers need it, put it in the code (it can also be in the commit).

## Comments as a design tool

- Write the class's interface comment and the main methods' signatures and interface comments before the bodies. Iterate until the structure feels right, then write fields with their comments, then fill in bodies.
- A comment that is hard to write (**hard to describe**) signals a bad abstraction. If an interface comment must describe the implementation to be complete, the module is shallow.

## Keeping comments correct

- Keep comments next to the code they describe; push each comment down to the narrowest scope it covers. The further a comment is from its code, the more abstract it should be.
- Document each decision once; elsewhere, point to it.
- Before committing, scan the diff and update every comment it affects.
- Higher-level comments survive code changes better than line-by-line ones.
