# Comments

Chapters 12, 13, 15, 16. Comments capture what the designer knew that the code can't express. Without them, an abstraction is only its signature, which is too little to use correctly. A comment exists only to save the reader a dig.

## The test

**Write a comment only when it answers a question a competent reader couldn't answer within a minute from the code in front of them.** Digging means reading another file, reading a body to learn how to call it, or running the code. If the answer is already in the name, the type or the next few lines, write no comment; if a better name or type would carry it (`durationMs`, a literal union, `readonly`), change the code instead.

## The six questions

A comment answers at least one of these; one that answers none is deleted.

| Question | Typical place |
|---|---|
| 1. What does this stand for, and what does it promise? The abstraction: what an instance represents, what it offers, its limits. | Before a class, an exported function, a public method. A caller should never need the body to call it. |
| 2. What does a value mean at its edges? `null` or empty, units, inclusive or exclusive bounds, invariants, who owns cleanup. Nouns, not verbs. | Beside a field, a parameter, a type. |
| 3. What happens besides the return value? Side effects, order, lifecycle, preconditions. | In the interface comment. |
| 4. How can it fail? TypeScript has no checked exceptions, so a signature can't say it. | `@throws` in the interface comment. |
| 5. Why is it this way? A non-obvious choice, a rejected alternative, a workaround (link the issue). | Next to the surprising code; inside a long body, one line before the block it explains. |
| 6. What else must change with it? A decision spread across modules. | Where developers go anyway (beside the enum everyone extends), or a design-notes section the code points to: "See 'X' in the README's design notes." |

Public interfaces nearly always answer questions 1, 3 or 4, so they nearly always get a comment. A private helper with a precise name usually doesn't. A field gets one for questions 2 or 5.

## How to write one

- Format: a TSDoc block (`/** */`) so editors show it on hover. Line comments (`//`) only inside bodies.
- The first sentence speaks from the caller's side: what it does or means, never how it works.
- Use precise words ("milliseconds", "null when no toast is on screen", "after the first successful load"), never vague ones ("handles", "manages", "data").
- Never repeat the name or the type. Never write a type in a comment.
- Tags: `@throws` whenever something can throw (question 4), and `@param name - …` only for a parameter whose meaning, unit or constraint goes beyond its name and type (editors show it while typing that argument). No `@returns`, no `{type}`, no `@example` in code; examples live in the README.
- One idea per comment, kept short.

## What not to write

- A comment that repeats the code. Check: could someone who has never seen this code write it just by reading the line beside it? Then delete it.
- A comment that reuses the words of the name it describes (`// Get normalized resource names` above `getNormalizedResourceNames`).
- Implementation details in an interface comment. Put them inside the body.
- An explanation of a called function at the call site; it belongs in the callee's interface comment.
- Rationale that lives only in a commit message. If future developers need it, it goes in the code (and may also be in the commit).

## Comments as a design tool

- Write the class's interface comment and the main methods' signatures and interface comments before the bodies. Iterate until the structure feels right, then write the fields with their comments, then fill in the bodies.
- A comment that is hard to write (**hard to describe**) signals a bad abstraction. If an interface comment must describe the implementation to be complete, the module is shallow.

## Keeping comments correct

- Keep comments next to the code they describe; push each comment down to the narrowest scope it covers. The further a comment is from its code, the more abstract it should be.
- Document each decision once; elsewhere, point to it.
- Before committing, scan the diff and update every comment it affects.
- Higher-level comments survive code changes better than line-by-line ones.
- In review, flag both directions: a question from the six left unanswered, and a comment that answers none.
