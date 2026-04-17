---
description: Run one OpenRing turn manually (mode picked by the user).
---

Run one OpenRing turn in the mode specified in $ARGUMENTS (`build` or `analyze`).

Steps:
1. Read `AGENTS.md` (memory + constitution) and `GOAL.md` (current objective).
2. Invoke the matching subagent:
   - `build` → `@builder` — make forward progress on the first unchecked goal, or the whiteboard instruction if one is set.
   - `analyze` → `@critic` — inspect the last commit for a concrete flaw, write a failing test if possible.
3. Let the subagent do its job per its own system prompt. Commit with the appropriate message prefix and append a Cycle Log bullet.
4. Report a one-line summary of what changed.

Useful for: manual turns outside the `openring.sh` scheduler (e.g. reviewing a specific PR, iterating by hand, debugging the preset).
