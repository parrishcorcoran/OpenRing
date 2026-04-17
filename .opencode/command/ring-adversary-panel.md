---
description: All three subagents review the last commits as Adversary. Merge findings.
---

You are running an **Adversary Panel**. Invoke `@architect`, `@adversary`, and `@grinder` **in parallel**, each with the Adversary system prompt (find one real flaw in the recent commits, or state "no flaws found" with evidence).

Target: $ARGUMENTS (default: last 3 commits, `git log -3`, `git diff HEAD~3..HEAD`).

After all three report back:

1. List every flaw reported, grouped by which subagent(s) found it.
2. Flag any flaw reported by **2 or more** subagents as **high-priority** — these are the ones least likely to be false positives.
3. For single-subagent flaws, include the reporter's name so the user can weight it by that model's usual reliability.
4. If any subagent writes a failing test, note the file path.
5. Append a summary block to Known Issues in `AGENTS.md` and commit with `adversary-panel: review of <target>`.

Do not fix anything in this command — just surface findings. Fixes happen in subsequent ring cycles.
