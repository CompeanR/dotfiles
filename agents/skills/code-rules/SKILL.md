---
name: code-rules
description: The user's code design rules, drawn from A Philosophy of Software Design. Use when writing, designing, refactoring, or reviewing code in any of the user's projects.
---

# Code rules

Every rule serves one goal: lower **complexity**, meaning anything about a system's structure that makes it hard to understand or change. It shows up as change amplification (one change, many edits), cognitive load (much to know before acting), and unknown unknowns (unclear what to change or know). It comes from **dependencies** and **obscurity**. When a rule doesn't lower complexity in a specific case, set it aside for that case and say why.

Source: John Ousterhout, _A Philosophy of Software Design_, 2nd ed. Shared vocabulary (module, interface, depth, seam): the `codebase-design` skill.

## How to apply

- **Writing or designing**: read the topic file for the work in front of you (table below) before you write the module. For a major interface in a new project or feature, design it twice and let the user pick (`process.md`). Before calling the work done, check the diff against every red flag.
- **Modifying existing code**: finish with the structure the code would have had if it had been designed with this change in mind. Leave the design a little better than you found it; a change that doesn't improve it is making it worse.
- **Reviewing**: check every hunk against every red flag. Report each hit with the flag name, the quoted hunk, and the fix. Each hit is a judgement call; a repo's own documented standard wins.

## Red flags

A red flag is a symptom that code is more complex than it needs to be. When you see one, look for a design that removes it; try more than one alternative before settling.

- **Shallow module**: the interface isn't much simpler than the implementation. → `modules.md`
- **Information leakage**: one design decision (a format, a protocol, an ordering) is known by several modules. → `modules.md`
- **Temporal decomposition**: modules split by execution order (read, then parse, then write) instead of by the knowledge each needs. → `modules.md`
- **Overexposure**: using a common feature forces callers to learn about rare ones. → `modules.md`
- **Pass-through method**: a method that forwards its arguments to another with a near-identical signature. → `modules.md`
- **Pass-through variable**: a value threaded through methods that don't use it, to reach one that does. → `modules.md`
- **Leaky getter**: a getter or setter that exposes internal state, or returns an internal collection by reference. → `modules.md`
- **Punted config**: a configuration parameter for something the module could compute or default itself. → `modules.md`
- **Special-general mixture**: a general-purpose mechanism holding code for one particular use of it. → `modules.md`
- **Repetition**: the same nontrivial code shape appears more than once. → `modules.md`
- **Conjoined methods**: you can't understand one method without reading another's implementation. → `modules.md`
- **Special-case sprawl**: flags and `if` checks for edge cases (`hasSelection`, `isEmpty`) that a better normal case would absorb. → `errors.md`
- **Scattered error handling**: many handlers doing the same thing, a `try/catch` per call, or errors thrown where the operation could have been defined to succeed. → `errors.md`
- **Comment repeats code**: everything in the comment is obvious from the code beside it, often reusing the name's own words. → `comments.md`
- **Implementation contaminates interface**: an interface comment describes how, when the caller only needs what. → `comments.md`
- **Hard to describe**: a complete comment for the method or variable would have to be long. → `comments.md`
- **Vague name**: a name broad enough to mean many things (`data`, `count`, `status`, `result` in a void function). → `names.md`
- **Hard to pick name**: no short, precise name comes; the thing probably has no clean definition. → `names.md`
- **Generic container**: a tuple, `Pair` or loose object returned instead of a named type with named fields. → `names.md`
- **Nonobvious code**: a first-time reader can't understand the behavior or meaning on a quick read. → `names.md`

## Topic files

| File | Read when |
|---|---|
| [complexity.md](complexity.md) | starting a task, scoping a change, deciding how much design to invest |
| [modules.md](modules.md) | designing a class, function or service interface; splitting or merging code |
| [errors.md](errors.md) | code throws, catches, returns error values, validates input, or branches on edge cases |
| [comments.md](comments.md) | writing or reviewing comments and interface docs |
| [names.md](names.md) | naming things, following conventions, making code obvious |
| [process.md](process.md) | designing a new module, writing tests, or working on performance |
