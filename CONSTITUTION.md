# 🏛️ The Constitution

This file is the project's hard firewall. Every agent reads it every cycle. Rules here win over anything in `RING_GOALS.md`, the cycle log, or any model's prior context.

If a goal in `RING_GOALS.md` conflicts with the Constitution, the agent must append the conflict to "Known Issues" and stop, instead of violating the Constitution.

## Scope of this file

Put **architectural non-negotiables** here — decisions that must survive a 50-cycle loop without erosion. Do not put day-to-day TODOs here; those belong in `RING_GOALS.md`.

Good examples of Constitution-worthy rules:
- "All persistence goes through the `storage/` module. No direct DB calls from handlers."
- "Public API shape in `src/api.rs` is stable. Additive changes only."
- "No new runtime dependencies without a justification line in this file."

## Default rules (edit for your project)

1. **Respect the toolchain.** Do not introduce a new language, package manager, or build system without updating this file first.
2. **Additive refactors by default.** Do not delete public functions, exported types, or foundational data structures. Deprecate, add alternatives, or schedule removal via `RING_GOALS.md`.
3. **No secrets in commits.** Never commit API keys, tokens, `.env` files, or anything resembling credentials.
4. **No ToS evasion.** Do not write code whose purpose is to bypass rate limits, disguise automated traffic as human traffic, or work around a vendor's terms of service.
5. **Tests accompany behavior changes.** Any cycle that changes observable behavior must add or update a test in the same commit, or log a `test-debt` entry in Known Issues.
6. **Smallest-diff principle.** Prefer the minimal change that meets the goal. Cleanup commits are separate from feature commits.
7. **Adversary must be honest.** When acting as Adversary, you must find a real flaw or explicitly state "no flaws found" with evidence of what you checked. Manufactured nits are a Constitution violation.

## Project-specific laws

*(Add your project's specific invariants below. These are the rules most at risk of being forgotten by cycle 40.)*

- _None yet. Add them before running the Ring on real code._
