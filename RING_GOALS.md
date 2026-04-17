# 🎯 Ring Shared State

This file is the shared blackboard. Agents read it at the start of every cycle and append to it at the end. It is the source of truth for "what is the Ring doing right now".

## Current Objective

Bootstrap OpenRing on this repository: verify the three CLIs are wired correctly, write one intentionally flawed function, and walk it through Architect → Adversary → Grinder to prove the loop produces a real fix.

## Checkboxes

- [ ] Confirm which of `claude`, `gh copilot`, `ollama` are available in this environment.
- [ ] Create a `sandbox/` directory with a deliberately flawed routine (e.g. an off-by-one, a leaked allocation, or an unchecked error path).
- [ ] Add a failing test that demonstrates the flaw.
- [ ] Let the Adversary cycle attack it and log the concrete failure mode in Known Issues.
- [ ] Let the Grinder cycle make the test green with the smallest possible diff.
- [ ] Remove the sandbox once the loop round-trips cleanly, or promote it to `examples/`.

## Known Issues (Adversary Logs)

_None yet. The first Adversary cycle will populate this section._

Format for new entries:

```
- [cycle N, commit <sha>] <one-line flaw description>
  repro: <exact command or test that fails>
  proposed fix: <one sentence>
```

## Cycle Log

_One bullet per cycle. Role, what changed, any follow-ups._

- [cycle 0] bootstrap: initialized Constitution, Goals, and orchestrator.

## Archive

_Populated by the summarizer once Cycle Log gets long._
