# Design process, tests and performance

Chapters 11, 15, 19, 20.

## Design it twice

For every major interface, sketch at least two radically different designs (even if you're sure there's only one sensible option) and compare them. The main criterion is ease of use for the code above; then simplicity, generality and efficiency. The winner may combine ideas, or the comparison may reveal a third design. Repeat for the implementation, where simplicity and performance matter most. For a class this takes an hour or two, not days. For parallel exploration, see `codebase-design`'s DESIGN-IT-TWICE.md.

## The increment is an abstraction, not a feature

Develop incrementally, but each increment adds or reshapes an abstraction. You can defer thinking about an abstraction until a feature needs it. When it does, design it whole: a reasonably complete, somewhat general core rather than one piece per feature.

## Tests

- Unit tests are what make refactoring safe, and strategic design depends on refactoring. Keep a strong suite.
- When using test-first development, design the interface first (design it twice, interface comments) and let tests drive the implementation, not the shape of the interface. Next-test-next-hack without a design step is tactical programming.
- For bug fixes, always write the failing test first, then fix, then see it pass.

## Performance

- Choose designs that are naturally efficient when they're just as simple: know what's expensive (network round-trips, disk and storage I/O, allocation, cache misses) and pick cheap options, like a hash map over an ordered map when order doesn't matter.
- If speed needs added complexity: accept it if it's small and hidden behind an unchanged interface. Otherwise start simple and optimize later, unless you have clear evidence up front that performance will matter.
- Measure before changing anything, and measure again after. Back out changes that don't measurably help, unless they made the code simpler.
- Prefer fundamental fixes (a cache, a better algorithm or data structure). When none exists, design around the **critical path**: imagine the minimum code the common case must run, then find a clean design close to that ideal. Check for all special cases with a single test up front and handle them off the critical path.
- Clean code is usually fast code: deep modules cross fewer layers, and code without special cases checks fewer conditions.
