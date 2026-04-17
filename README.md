# ⭕ OpenRing

**An unattended multi-model review loop for [opencode](https://opencode.ai). Rotates Claude, Copilot, and Gemini through Architect / Adversary / Grinder roles, with a git-backed whiteboard you can edit from anywhere to steer the loop while it runs.**

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Install](https://img.shields.io/badge/install-1_line-brightgreen.svg)
![Status](https://img.shields.io/badge/status-experimental-orange.svg)

Run it overnight on a scratch branch. Wake up to a branch of reviewed commits, a ledger of issues the adversary found, and a redacted log tail you can peek at from your phone.

---

## The honest, research-grounded pitch

Most multi-agent coding frameworks fail to beat a well-prompted single agent at equal compute. The literature is pretty clear about this:

- [Multi-agent debate doesn't reliably outperform self-consistency](https://proceedings.mlr.press/v235/smit24a.html) (ICML 2024).
- [Single-agent matches multi-agent at equal token budget](https://arxiv.org/html/2604.02460v1) on reasoning.
- [MetaGPT's 85.9% HumanEval was vs a badly-underreported 67% GPT-4 baseline](https://github.com/geekan/MetaGPT/issues/418); real single-agent GPT-4 is 86.59%.
- Multi-agent setups consume [4-220× more tokens than single-agent](https://d2jud02ci9yv69.cloudfront.net/2025-04-28-mad-159/blog/mad/).

**But when they do win, the gains are real and the failure modes of single-agent are well-documented.** On SWE-bench Verified, [a multi-agent team with a dedicated reviewer hits ~72% vs ~65% single-agent using the same base model](https://aclanthology.org/2025.acl-long.189.pdf) — 7% absolute from structure alone. The mechanism: specialization plus cross-validation from a different perspective.

The single-agent failure modes multi-agent can address (when done right):
- **Degeneration-of-thought** — a model critiquing its own output [repeats its own reasoning errors across iterations](https://arxiv.org/html/2512.20845).
- **Own-family preference** — models prefer outputs from their own training family, so same-model critique rubber-stamps.
- **Self-correction plateau** — [LLMs can't reliably fix their own errors without external feedback](https://proceedings.iclr.cc/paper_files/paper/2024/file/8b4add8b0aa8749d80a34ca5d941c355-Paper-Conference.pdf).

**OpenRing's architecture is designed to hit every one of these conditions deliberately** — heterogeneous model families per role, mandatory critic with evidentiary requirements, persistent git-backed state, forced rotation, verification-friendly task shape, long-horizon by design, cost bounded by Ollama hot-swap.

On bounded, verifiable, long-horizon coding tasks — bug hunts, test coverage, invariant enforcement, iterative refactors — this is where the research says multi-agent *genuinely* works, and OpenRing targets that band on purpose. Expect 10-50% improvement on the right task structure, with occasional finds a single-agent loop would miss.

For open-ended greenfield design, a well-prompted single Claude Opus call is often still your best bet. Honest is honest.

Full citations and reasoning: [RESEARCH.md](./RESEARCH.md).

---

## The four things that make it work

1. **🧠 Architect** — `anthropic/claude-sonnet-4-5` by default. Picks the next goal from `AGENTS.md` (or the `WHITEBOARD.md` instruction if non-empty), implements, commits.
2. **🛡️ Adversary** — `github-copilot/gpt-5` by default, a *different model family*. System-prompted to require a concrete reproducer: a failing test or explicit "no flaws found, verified by X" log. Manufactured nits are a constitution violation.
3. **⚙️ Grinder** — `google/gemini-2.5-pro` by default. Runs build/tests/lint, fixes red with smallest-diff commits. No architectural changes.
4. **🔧 Ollama hot-swap** — when a plan model rate-limits or errors, the same prompt re-runs through your local Ollama model so the cycle isn't wasted. Optional 4-way rotation lets Ollama do free mechanical work every 4th cycle.

Plus two operational pieces:

- **🪧 Whiteboard (`WHITEBOARD.md`)** — plain markdown in the repo. Edit it from your phone's GitHub editor, from Cursor, from the Vercel dashboard. Next cycle the Architect reads it, addresses it, and wipes it clean. Your remote-control surface costs nothing and runs anywhere git runs.
- **📡 Vercel dashboard** (optional) — [live peek from anywhere](./dashboard). Shows cycle #, role, model, stall count, last commit SHA, and a **redacted** truncated tail. Only metadata crosses the wire; source and diffs stay in git. Same whiteboard, edited via textarea. Pause / resume / skip / force-adversary / stop buttons.

## 🚀 Quick Start

```bash
# 1. Install opencode — https://opencode.ai

# 2. Log into the providers you have plans for (no API keys needed)
opencode auth login   # pick Anthropic
opencode auth login   # pick GitHub Copilot
opencode auth login   # pick Google

# 3. (Optional) Install Ollama for hot-swap fallback
ollama pull qwen2.5-coder

# 4. Install OpenRing
curl -fsSL https://raw.githubusercontent.com/parrishcorcoran/OpenRing/main/install.sh | bash

# 5. In your project
cd your-project
cp ~/.openring/AGENTS.md.template      ./AGENTS.md
cp ~/.openring/WHITEBOARD.md.template  ./WHITEBOARD.md
cp -r ~/.openring/.opencode            ./
# edit AGENTS.md to describe your project
openring
```

## 📁 What gets installed into your project

```
your-project/
├── AGENTS.md                              # constitution + goals (opencode-native)
├── WHITEBOARD.md                          # remote-control surface, editable from anywhere
└── .opencode/
    ├── agent/
    │   ├── architect.md                   # Claude Sonnet
    │   ├── adversary.md                   # Copilot GPT
    │   └── grinder.md                     # Gemini
    └── command/
        ├── ring-cycle.md                  # manual single cycle
        ├── ring-vote.md                   # all 3 vote on a decision
        └── ring-adversary-panel.md        # 2-of-3 agreement flags high-priority flaws
```

> opencode's subagent/command directory names have shifted across versions (`.opencode/agent/` vs `.opencode/agents/`, etc). If the preset doesn't load, rename and file a one-line PR — the preset content is just markdown.

## 🌀 How the loop works

Each cycle, `openring.sh` does exactly the things opencode can't do on its own:

1. **Pulls remote state.** `git pull` to pick up GitHub-edited whiteboards. `GET /api/whiteboard` to pick up Vercel-edited whiteboards. Whichever is newer wins.
2. **Checks for hard-stops in the whiteboard.** Lines reading exactly `STOP`, `PAUSE`, or `FORCE ADVERSARY` short-circuit the normal cycle.
3. **Polls the dashboard** (if configured) for control commands: pause / resume / skip / force-adversary / stop.
4. **Picks a role.** Round-robin through Architect → Adversary → Grinder (4-way with Ollama if enabled). With probability `CHAOS_RATE` (default 20%), forces an Adversary cycle regardless — the Architect can't choose when to get critiqued.
5. **Posts status + redacted tail** to the dashboard (metadata only, secrets scrubbed both client- and server-side).
6. **Invokes opencode** with the subagent and the role prompt. Agent reads `AGENTS.md`, maybe `WHITEBOARD.md`, does its work, commits, appends to the Cycle Log. On provider failure, hot-swaps to Ollama for that cycle.
7. **Syncs whiteboard back** to the dashboard after Architect cycles (so "cleared" state propagates).
8. **Checks for stalls** via `git write-tree` hash. If 3 consecutive cycles touch zero files, a **circuit breaker** trips: next cycle is forced to Architect with a prompt to shrink-or-block the current objective.
9. **Pushes commits** to remote if `OPENRING_REMOTE_BRANCH` is set.

## ⚙️ Configuration

Env vars, defaults shown:

```bash
# Models — override to match what your opencode auth login gives you
ARCHITECT_MODEL="anthropic/claude-sonnet-4-5"
ADVERSARY_MODEL="github-copilot/gpt-5"
GRINDER_MODEL="google/gemini-2.5-pro"
OLLAMA_MODEL=""                            # e.g. "ollama/qwen2.5-coder"
OLLAMA_IN_ROTATION=0                       # 1 = Ollama is every 4th role

# Loop behavior
MAX_CYCLES=15
CHAOS_RATE=20                              # % chance of forced Adversary
STALL_LIMIT=3                              # no-progress cycles → circuit breaker
COOLDOWN=5                                 # seconds between cycles

# Optional remote
OPENRING_DASHBOARD_URL=""                  # e.g. https://your-ring.vercel.app
OPENRING_DASHBOARD_TOKEN=""                # matches OPENRING_TOKEN on Vercel
OPENRING_REMOTE_BRANCH=""                  # e.g. "origin main" to pull/push each cycle
```

Model IDs shift as vendors ship new versions. Run `opencode models` to see what your logins currently have access to.

## 🔒 The Constitution

`AGENTS.md` has a Constitution section — project invariants every agent reads every cycle. Put your non-negotiables here (language choice, public API shape, dependency policy) so long-running loops don't hallucinate them away on cycle 47. The default template ships with sensible project-agnostic rules (no secrets, no ToS evasion, smallest-diff, Adversary-must-be-honest); add your project-specific rules below them.

## ⚠️ Honest caveats

- **Experimental.** Unattended commit loops produce broken commits sometimes. Run on a scratch branch.
- **Plan limits are real.** Your Claude / Copilot / Gemini subscriptions have caps. `MAX_CYCLES=500` will hit them. Ollama fallback is what keeps the loop moving when you do.
- **No ToS evasion.** opencode uses each vendor's sanctioned OAuth flow. OpenRing doesn't disguise traffic, bypass rate limits, or use plans in ways their terms forbid.
- **Task fit matters.** Bounded verifiable work (bugs, tests, refactors with tests as ground truth) — expect real gains. Open-ended creative or architectural design — expect no better than a single strong model. See [RESEARCH.md](./RESEARCH.md).
- **Review your diffs.** The Ring produces candidate code quickly. A human still merges.
- **Preset, not magic.** The intelligence comes from opencode and the models. OpenRing is the clock, the referee, and the steering wheel.

## License

MIT
