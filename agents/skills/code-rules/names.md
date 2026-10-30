# Names, consistency and obvious code

Chapters 14, 17, 18. Code is **obvious** when a first-time reader's quick guesses about it are correct. Design for ease of reading, not ease of writing.

## Names

A name should create a picture: seen alone, without its declaration or docs, a reader should guess what it refers to and what it doesn't. A name is a small abstraction: two or three words that capture what matters most.

- **Precise**: `numActiveIndexlets`, not `getCount`; `charIndex` and `lineIndex`, not `x` and `y`; `NOT_YET_VOTED`, not `VOTED_FOR_SENTINEL_VALUE`.
- **Booleans are predicates**: `cursorVisible`, not `blinkStatus`.
- **Not too specific either**: a function that deletes any range takes `range`, not `selection`.
- `result` only names the value a function returns.
- Short names (`i`, `j`) are fine when the whole span of use fits on screen. The farther a name is from its declaration, the longer it should be.
- When two things are easy to confuse (file block vs. disk block), give them distinct names, and ideally distinct types.
- Drop words that add nothing: `file`, not `fileObject`; `block`, not `fileBlock` inside a `File` class; no type prefixes.
- If no good name comes (**hard to pick name**), the thing probably does too much. Split the concept.

## Consistency

Similar things are done the same way, and different things differently.

- Pick one name per recurring concept and use it everywhere, only for that concept. Use prefixes for variants (`srcFileBlock`, `dstFileBlock`).
- **When in Rome**: before writing in an existing file or project, look at how it already names, orders and structures things, and follow that. When making a design decision, look for a similar decision already in the project and copy it.
- Don't change an existing convention for a "better idea" unless the new information is significant and you'll update every old use.
- Enforce conventions with tooling (lint, pre-commit checks) wherever possible.
- Don't force dissimilar things into one pattern or name; consistency only helps when "looks like X" really means "is X".

## Making code obvious

- Use blank lines to separate the major blocks in a function, each led by a one-line comment.
- Return a named type, never a tuple or generic pair:

```ts
// Reader must guess what [0] and [1] mean
return [currentTerm, false];

// Obvious at every call site
return { currentTerm, voteGranted: false };
```

- Match a variable's declared type to its actual type when the difference matters to readers.
- Event-driven handlers hide control flow: say in each handler's interface comment when and from where it is invoked.
- Code that breaks a reader's expectation (a constructor that starts background work, a function that mutates its argument) needs a comment at the surprising spot.
- Code is made obvious in three ways, best first: reduce what readers need to know (abstraction, removing special cases); reuse what they already know (conventions); show them what they need (names, strategic comments).
