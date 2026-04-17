---
description: All three rotation models review the last commits as Critic. Merge findings.
---

You are running a **Critic Panel**. Invoke all configured rotation models **in parallel**, each under the Critic prompt from `.opencode/agent/critic.md` (find one real flaw with a reproducible repro, or state "no flaws found" with evidence of what was checked).

Target: $ARGUMENTS (default: last 3 commits — `git log -3`, `git diff HEAD~3..HEAD`).

After all three report back:

1. List every flaw reported, grouped by which model(s) found it.
2. Flag any flaw reported by **2 or more** models as **high-priority** — these are the ones least likely to be false positives from a single model's bias.
3. For single-reporter flaws, include the reporter's model name so the user can weight by their usual reliability.
4. If any model wrote a failing test, note the file path.
5. Append a summary block to Known Issues in `AGENTS.md` and commit with `critic-panel: review of <target>`.

Do not fix anything in this command — just surface findings. Fixes happen in subsequent turns.
