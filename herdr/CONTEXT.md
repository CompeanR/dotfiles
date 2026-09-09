# Herdr Agent Navigation

This context describes how a user moves among AI agents represented in Herdr.

## Language

**Agent**:
An AI process associated with a Herdr pane and represented in the agent panel.

**Machine**:
A host running its own Herdr server: Local, or a saved SSH machine. Every Agent and Space belongs to exactly one Machine, and their identifiers and positions are unique only within it — two Machines may hold Spaces of the same name and number.
_Avoid_: Host, endpoint, server, remote

**Space**:
A workspace on one Machine, holding the tabs and panes of a single piece of work. A Space is addressed by its position within its own Machine, never across Machines.
_Avoid_: Session, window, project

**Attention Order**:
The shared display and forward-navigation order that prioritizes agents needing user intervention, followed by working agents and then idle agents. Agents in the same state are ordered by longest time waiting in that state. It spans every Machine, so an Agent's Machine never affects its place in the order.
_Avoid_: Spatial order, most-recent-first order, per-Machine order

**Agent Cycle**:
A repeating forward traversal of every agent in Attention Order. It uses the latest agent states on each step, so a newly blocked agent can preempt the prior sequence.
_Avoid_: Blocked-only cycle, fixed snapshot

**Navigation History**:
The sequence of agents the user has actually left through any focus mechanism, including shortcuts, panel selection, notifications, and commands. “Previous agent” returns through this history rather than reversing the current Attention Order.
_Avoid_: Reverse cycle, shortcut-only history
