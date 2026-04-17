---
description: Run one OpenRing cycle manually (role picked by the user).
---

Run one OpenRing cycle as the role specified in $ARGUMENTS (one of: `architect`, `adversary`, `grinder`).

Steps:
1. Read `AGENTS.md`.
2. Invoke the matching subagent (`@architect`, `@adversary`, or `@grinder`).
3. Let it do its job per the subagent's own system prompt: edit files, run checks, commit with the role prefix, append to the Cycle Log.
4. Report a one-line summary of what the cycle changed.

This command is useful for manual cycles outside the `openring.sh` scheduler — e.g. when reviewing a specific PR or iterating on one feature by hand.
