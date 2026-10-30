# Modules and interfaces

Chapters 4–9, 19. A module is anything with an interface and an implementation: a function, class, package or service.

## Make modules deep

The best module hides a lot of functionality behind a simple interface. The interface is the cost a module imposes on everyone else; the functionality is its benefit.

- Prefer a few powerful methods over many small ones. Unix file I/O hides a huge implementation behind five calls.
- Don't split classes or functions just because they're long. Many tiny classes ("classitis") each add an interface to learn. A long function with a simple signature that reads well is fine.
- The interface includes informal parts: behavior, ordering constraints, side effects, errors. If a caller must know it, it's part of the interface.
- A false abstraction hides something callers actually need. Hide only what is truly unimportant to them.

## Hide information; watch for leakage

Each module should own a few design decisions (a data format, an algorithm, a protocol) that no other module needs to know.

- **Leakage** means the same knowledge lives in several modules, even with no shared interface (a reader and a writer that both know a file format). Fix it by merging the modules or by pulling the knowledge into one module with a simple interface.
- **Temporal decomposition** is the usual cause: splitting by the order things happen. Split by knowledge instead. Reading and parsing an HTTP request belong together because both need the format.
- `private` is not information hiding if getters and setters expose the same state. Return what callers need, not your internal structures:

```ts
// Leaks the representation
public getParams(): Map<string, string> { return this.params; }

// Hides it
public getParameter(name: string): string { ... }
public getIntParameter(name: string): number { ... }
```

- Within a class too: give each private method one piece of knowledge, and keep each field used in as few places as possible.
- Don't hide what callers genuinely need. Tuning knobs that different callers must set differently belong in the interface.

## Make the common case simple

- Give defaults for what nearly everyone wants; offer an override separately so most callers never see it. Buffering should come built in, not as a wrapper callers must remember.
- Classes should do the right thing without being asked.
- Avoid configuration parameters. Before exporting one, ask whether callers can really pick a better value than the module can compute (measure it, adapt it). If a parameter is truly needed, default it.

## Somewhat general-purpose

The module's functionality reflects today's needs; its interface shouldn't be tied to them.

- Text storage exposes `insert(position, text)` and `delete(start, end)`, not `backspace(cursor)` and `deleteSelection(selection)`. UI concepts stay in the UI.
- Ask: what is the simplest interface that covers all my current needs? In how many situations will this method be used? (One means it's probably too special.) Is it still easy to use for my current need? (If callers write lots of glue, it's too general or too low.)
- **Push specialization up** into the top-level feature code, or **down** into adapters behind a general interface (device drivers). Keep it out of the general mechanism.
- Separate a general mechanism from its special uses: a `History` that manages undo actions knows nothing about what each action does.

## Different layer, different abstraction

Each layer should offer a different abstraction from the one below it.

- **Pass-through methods** (forwarding to a near-identical signature) add interface without adding function. Fix by letting callers use the lower class directly, by redistributing responsibilities, or by merging the classes.
- Same signature is fine when each method adds real function: a dispatcher choosing a handler, or several implementations of one interface.
- Decorators and wrappers tend to be shallow. Before writing one, try adding the feature to the class itself, to the use case, or to an existing decorator, or making it a standalone class. Wrapping an external API you can't change is the legitimate case.
- A class's interface should differ from its representation: store lines internally, expose character ranges.
- **Pass-through variables**: instead of threading a value through methods that don't use it, put shared state in a context object, passed only to constructors and stored on the objects that need it. Keep the context's fields immutable and its contents intentional.

## Pull complexity downward

When complexity is unavoidable and belongs to the module's function, handle it inside the module rather than exposing it. A module has more users than maintainers, so it's better for the maintainer to suffer. Pull complexity down when it is closely related to the module's existing function, simplifies code elsewhere, and simplifies the interface. Moving UI knowledge into a text class does none of these, so it is just leakage.

## Together or apart

Every split adds an interface, distance and sometimes duplication. Bring code together when it shares information, is always used together (in both directions), overlaps conceptually, or can't be understood without the other piece. Merge when it simplifies the interface or removes duplication. Keep it apart when it is general versus special-purpose, or when combining makes the code more awkward (cursor and selection are better as two simple `Position` values than one combined object).

- **Repetition**: extract repeated code when the snippet is long and the new function has a simple signature, or restructure so the code runs in one place.
- Don't create tiny one-call helpers (a `NetworkErrorLogger.logRpcOpenError` used once); keep the code where it's used.
- **Splitting a function** is worth it when it produces cleaner abstractions: a cleanly separable subtask (readable without the parent, ideally general) or two independent capabilities, each simpler than the original. If callers then have to call both pieces in order, or a reader has to flip between them, the split was wrong (**conjoined methods**).
- Depth over length: make functions deep first, then short enough to read. Never trade depth for shortness.

## Object-oriented features

- Interface inheritance is good: the more implementations an interface has, the deeper it is.
- Implementation inheritance couples parent and children through shared state. Prefer composition with helper classes. If you must inherit, keep each field owned by one level of the hierarchy.
- Design patterns help only when they fit; don't force a problem into one.
- Avoid getters and setters as a default pattern: they are shallow and expose implementation. Don't expose fields in the first place.
