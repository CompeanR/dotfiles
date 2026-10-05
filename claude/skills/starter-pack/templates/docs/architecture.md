# Architecture

**The main objective is small interfaces and deep modules.** Every module hides a lot of behaviour behind a small
interface. {{How this stack expresses a module and its public interface: exported names, public methods, a header, a package.}}

## Vocabulary

The words of the codebase-design skill. Use them exactly in reviews, commits and docs.

- **Module**: anything with an interface and an implementation. A function, a type, a package.
- **Interface**: everything a caller must know to use the module: the signatures, but also invariants, call order,
  error modes and required configuration. Not only the language's `interface` keyword.
- **Depth**: how much behaviour a caller gets per unit of interface it has to learn. A module is **deep** when a lot
  of behaviour sits behind a small interface, and **shallow** when the interface is nearly as big as the code.
- **Small interface** is the good shape; **shallow module** is the bad one.

## Folder tree by feature

{{The real tree in a code block, one line per folder saying what it owns. One module per feature; the composition root is the only place that builds infrastructure.}}

## Public surface

{{What the outside world calls: HTTP routes, CLI commands, wire types, hardware API. A table of entry point, input and output. Drop the section when there is none.}}

## Rules

{{Numbered rules that follow from the principles and that review or lint enforces: the exported names are the interface; policy apart from I/O; accept dependencies, do not create them; inject the clock and the process runner; return concrete types; no comments.}}

## The deletion test

Imagine deleting a type, an interface, a method, a helper or a file. If deleting it only moves its lines into the
caller, it was a wrapper and must go. If its complexity would reappear in every caller, it earns its place.

## The `gd` hop test

From any public method, go-to-definition must reach the work in **at most two hops**: the public method, then the
method whose body does the I/O. A third hop (an interface, a wrapper, a same-name helper, a utility) is a defect.

## Dependency categories decide how a module is tested

| Category | Examples | Test |
|---|---|---|
| In-process | state rules, views, parsing | Through the interface. No adapter. |
| Local-substitutable | {{databases, files, git repositories}} | The real thing in a temp dir or container. No fake. |
| True external | {{third-party APIs, the clock, notifications}} | Injected, with a test adapter or a fake on the path. |

**Replace, don't layer.** Once a behaviour is pinned at the deeper interface, delete the lower test that only
repeats it. Tests assert what callers can observe, never internal state or call chains.

## Readability

Agents copy the code around them, so every change keeps it readable.

{{The limits the linter enforces: name length, complexity, nesting, parameters, results. Name the config file that holds them.}}

## Module review (definition of done)

Run it on every module a change adds or touches.

1. **Count the exported names** and the parameters of each.
2. **Count the hops** from every public method to the I/O. More than two is a defect.
3. **Run the deletion test** on each type, interface, method, helper and file.
4. **Check the seams.** Every interface left sits at a true external boundary with a real second implementation.
5. **Check the tests.** They cross the interface callers use, with the real local dependencies, and only the true externals faked.

Exported names, interfaces, fakes, helpers and passthroughs stay flat or go down.
