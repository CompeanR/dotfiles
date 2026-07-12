# Companion Extension for Pi Multitask (not a fork)

We want Cursor Desktop Multitask-like behavior in Pi without pretending full product parity. Delivery is an update-safe Companion Extension: First Slice is Auto-resume (debounced wake + one integration turn, no double-fire), preserving Shared Transcript Illusion and Soft Parallel. We rejected forking `pi-subagents`, true shared transcripts, and True Multi-lane Parent (parked). Fan-out on Send and Write Grant come after First Slice is reliable; upstream PRs may follow in parallel but are not the ship path.

## Considered Options

- Fork / patch `pi-subagents-j0k3r` for `triggerTurn` — cleaner locally, owns a fork forever
- Wait for upstream only — correct long-term, blocks delivery
- Companion Extension now + upstream in parallel — chosen

## Consequences

- First Slice difficulty stays extension-layer (hours to ~1–2 days) unless completion hooks are insufficient
- Cursor-bin identical multi-lane parents remain out of scope until core/TUI work exists
