# ⭕ OpenRing

**A multi-agent orchestrator built on [`opencode`](https://opencode.ai). Rotates Claude, Copilot, Gemini, and a local Ollama model through Architect / Adversary / Grinder roles — funded by plan logins, no API keys.**

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Install](https://img.shields.io/badge/install-1_line-brightgreen.svg)
![Status](https://img.shields.io/badge/status-experimental-orange.svg)

OpenRing is a thin orchestration layer on top of [opencode](https://opencode.ai), the open-source agentic coding CLI. opencode is the agent — it edits files, runs bash, and makes commits. OpenRing rotates it through three different provider/model backends with three different system prompts, so the code that gets committed is written by one model and critiqued by a different one.

Because opencode authenticates to each provider with `opencode auth login` using each vendor's official OAuth flow for third-party clients, your **plan subscription** funds the loop. No API keys, no per-token billing. Ollama rounds it out as a free local fallback that hot-swaps in when a plan model rate-limits or runs out of credits.

## ✨ Why it actually produces better code

Single-agent coding loops suffer from **consensus bias**: the model that wrote the code is the same model grading the code, so it rubber-stamps its own work. OpenRing breaks that loop by:

- **🧠 Architect** (default: `anthropic/claude-sonnet-4-5`) — picks the next goal and implements it.
- **🛡️ Adversary** (default: `github-copilot/gpt-5`) — a *different model family* required to find a concrete, reproducible flaw. A failing test is the preferred output.
- **⚙️ Grinder** (default: `google/gemini-2.5-pro`) — runs build/tests/lint and fixes whatever is red with the smallest possible diff.
- **🔧 Ollama fallback** (optional, e.g. `ollama/qwen2.5-coder`) — hot-swaps in when a plan model errors, and optionally joins the rotation as a 4th role for free local grinder work.

This is not "emergent superintelligence" — it's just good engineering hygiene: different incentives per role, a different model per role so they don't agree out of training similarity, and written-down state (`CONSTITUTION.md` + `RING_GOALS.md`) instead of a drifting chat history.

## 🚀 Quick Start

**1. Install opencode** — https://opencode.ai

**2. Log into the providers you have plans for:**

```bash
opencode auth login  # pick Anthropic, log in with Claude Pro/Max
opencode auth login  # pick GitHub Copilot, log in with GitHub
opencode auth login  # pick Google, log in with your Gemini plan
```

**3. (Optional) Install Ollama** for the free local fallback:

```bash
# https://ollama.com
ollama pull qwen2.5-coder       # ~4GB, fast hot-swap
# or a heavier option:
ollama pull deepseek-coder-v2
```

**4. Install OpenRing:**

```bash
curl -fsSL https://raw.githubusercontent.com/parrishcorcoran/OpenRing/main/install.sh | bash
```

(Audit the installer first: [`install.sh`](./install.sh). ~60 lines, no binaries, no shell-rc edits.)

Or clone manually:

```bash
git clone https://github.com/parrishcorcoran/OpenRing.git
cd OpenRing
./openring.sh
```

**5. Run the Ring** in any git repo that has `CONSTITUTION.md` and `RING_GOALS.md`:

```bash
cd your-project
openring
```

## 🌀 How it works

1. Each cycle picks a role from the round-robin (`Architect → Adversary → Grinder`, or 4-way with Ollama).
2. With probability `CHAOS_RATE` (default 20%) the role is overridden to **Adversary**.
3. The agent reads `CONSTITUTION.md` (hard rules) and `RING_GOALS.md` (shared checklist + known issues).
4. opencode edits files, commits, and updates `RING_GOALS.md` with what it did and any new issues.
5. If the primary model errors (rate limit / auth / credits), OpenRing **hot-swaps to Ollama** for that cycle and keeps moving.
6. A **Circuit Breaker** watches the git tree hash. If 3 consecutive cycles make zero file changes, it forces the next Architect turn to shrink-or-block the current objective.
7. A **Context Summarizer** compresses `RING_GOALS.md` every 10 cycles (or when it exceeds 800 lines) so the loop can run for days without agents drowning in their own logs.

## ⚙️ Configuration

Everything is env-var tunable. Defaults shown.

```bash
ARCHITECT_MODEL="anthropic/claude-sonnet-4-5"
ADVERSARY_MODEL="github-copilot/gpt-5"
GRINDER_MODEL="google/gemini-2.5-pro"
OLLAMA_MODEL=""                    # e.g. "ollama/qwen2.5-coder"
OLLAMA_IN_ROTATION=0               # 1 = include Ollama as a 4th role
MAX_CYCLES=15
CHAOS_RATE=20                      # % chance of a forced Adversary cycle
STALL_LIMIT=3                      # no-progress cycles before breaker trips
SUMMARIZE_EVERY=10
GOALS_SOFT_CAP=800                 # lines in RING_GOALS.md
COOLDOWN=5                         # seconds between cycles
```

Model IDs shift as vendors release new versions. Run `opencode models` to see what your logins currently have access to, and override the env vars to match.

## 🔒 The Constitution

`CONSTITUTION.md` is the project-specific firewall. Every agent reads it every turn. Put your non-negotiable architectural decisions here (language choice, memory rules, public API shape) so long-running loops don't hallucinate them away on cycle 47.

## ⚠️ Limits and honest caveats

- **Experimental.** Autonomous commit loops produce broken commits sometimes. Run on a scratch branch.
- **Plan limits exist.** Your Claude / Copilot / Gemini subscriptions have usage caps. If you crank `MAX_CYCLES` to 500 you will hit them. Ollama fallback is what lets the loop keep moving when you do.
- **No ToS evasion.** opencode uses each vendor's sanctioned OAuth flow for third-party clients. OpenRing does not disguise traffic, bypass rate limits, or run headless on plans whose terms forbid it. Check your own plan's terms if you're unsure.
- **No magic.** OpenRing is ~200 lines of bash around opencode. The intelligence comes from the models.
- **Review your diffs.** The Ring produces candidate code quickly. A human still merges.

## License

MIT
