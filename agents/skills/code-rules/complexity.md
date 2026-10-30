# Complexity and the strategic mindset

Chapters 1–3, 16, 21.

## Complexity is incremental

Complexity is never one big mistake; it is hundreds of small dependencies and obscurities that each looked harmless. "A little complexity for this change is fine" is exactly how systems rot. Hold **zero tolerance**: sweat the small stuff.

- Complexity is judged by the reader, not the writer. If a reviewer finds code complex, it is complex; find out why instead of arguing.
- Weight complexity by how often people touch it. Complexity isolated where nobody needs to look is almost as good as gone.
- Fewer lines is not the same as simpler. A longer version that lowers cognitive load wins.

## Strategic, not tactical

**Tactical** programming optimizes for getting this feature working now and accumulates kludges. **Strategic** programming treats working code as necessary but not enough: the primary goal is a great design that also works.

- Invest roughly 10–20% of effort in design: proactively (try alternatives, write the interface docs) and reactively (fix a design problem when you find it, rather than patching around it).
- Make the investment today. "Clean it up after the crunch" becomes permanent.
- When fixing a bug or adding a feature, resist the smallest-possible-diff mindset. Ask whether the current design is still right given the change; if not, refactor toward it. If the right refactor is too big now, find the cleanest change you can afford and open an issue for the rest.

## Decide what matters

Good design separates what matters from what doesn't and builds around what matters.

- **Minimize what matters**: fewer required parameters, sensible defaults, errors handled low enough that nobody above sees them, settings computed instead of configured.
- **Emphasize what does matter**: put it where it's seen (interface docs, names, parameters of heavily used methods) and at the center of the structure.
- Two mistakes: treating too many things as important (clutter, shallow classes, arguments most callers ignore) and missing something important (hidden information, functionality callers must keep re-creating).
- When unsure what matters, state a hypothesis, build on it, and learn from whether it held.
