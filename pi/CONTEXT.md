# Pi Multitask

Domain language for bringing Cursor Desktop Multitask-style behavior into the Pi agent setup under `~/.pi` / this `pi/` tree.

## Language

**Multitask**:
The product goal of running parallel work in one Pi conversation with visible task status, culminating in both delegated workers and parallel user turns.
_Avoid_: concurrency, background mode, multitasking (vague)

**Delegated Parallelism**:
Fan-out of isolated subagent workers from a parent turn, with status and results returning into the parent thread. Already largely provided by `pi-subagents`.
_Avoid_: Multitask (when only this half is meant), Task mode

**Parallel User Turns**:
The ability for the user to send new requests while other work is already running in the same conversation, without those requests merely queuing behind the current turn.
_Avoid_: steering, follow-up (when true parallelism is meant)

**North Star**:
Full Multitask parity (Delegated Parallelism + Parallel User Turns). Delivery order is Delegated Parallelism first, then Parallel User Turns.
_Avoid_: MVP, phase 1 (unless tied to these terms)

**Shared Transcript Illusion**:
One parent timeline that shows worker status and completions as part of the conversation, while workers remain isolated and receive only a curated brief — not the full parent transcript.
_Avoid_: shared context, shared memory, inherited transcript

**Auto-resume**:
Waking the idle parent when background workers complete so it can integrate results into the Shared Transcript Illusion, preferably debounced across concurrent completions.
_Avoid_: silent land, steer-only completion, triggerTurn false (as the desired end state)

**Companion Extension**:
An update-safe Pi extension in this tree that implements Multitask behavior (starting with Auto-resume) without forking `pi-subagents`. Upstream package changes may follow in parallel but are not the delivery path.
_Avoid_: fork, patch vendor package, core Pi fork

**Soft Parallel**:
Parent stays interactive while Delegated Parallelism workers run; new user messages are parent turns or steers, not automatic new workers.
_Avoid_: Parallel User Turns (when only this is meant)

**Fan-out on Send**:
A new user message while the session is busy may spawn another background worker, with status and completion flowing through the Shared Transcript Illusion.
_Avoid_: true multi-lane parent, Soft Parallel

**True Multi-lane Parent**:
Multiple concurrent parent agent loops in one session. Parked — out of scope for Companion Extension delivery.
_Avoid_: Multitask (as a synonym for this alone)

**Write Grant**:
Explicit permission for a worker to mutate files, typically via an isolated worktree rather than the live shared tree. Without a Write Grant, workers are read-only.
_Avoid_: parent does all writing, same-tree honor system

**First Slice**:
The first Companion Extension deliverable: Auto-resume only. Status polish and Fan-out on Send come after Auto-resume is reliable.
_Avoid_: full Multitask, Fan-out on Send (as v1)

**First Slice Done**:
Auto-resume is complete when an idle parent wakes after debounced worker completions, performs one integration turn over the landed results, and does not double-fire while already mid-turn.
_Avoid_: wake works (alone), silent land
