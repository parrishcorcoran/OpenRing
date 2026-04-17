# ⭕ OpenRing

**An unattended multi-model review loop for [opencode](https://opencode.ai). Rotates Claude, Copilot, and Gemini through Architect / Adversary / Grinder roles with a forced schedule and a stall-detection circuit breaker — so you can kick off a coding session, walk away, and come back to a branch of reviewed commits.**

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Install](https://img.shields.io/badge/install-1_line-brightgreen.svg)
![Status](https://img.shields.io/badge/status-experimental-orange.svg)

## What this is (and isn't)

**What it is:** a small, opinionated opencode preset. A set of subagent configs, slash commands, an `AGENTS.md` template, and a ~60-line `openring.sh` scheduler that loops opencode with forced role rotation and an external stall breaker.

**What it isn't:** an agent. opencode is the agent. OpenRing is the clock and the referee.

Everything opencode already does well — multi-provider routing via plan logins, subagents, `AGENTS.md` persistent memory, `/compact` for context — OpenRing *uses*, it doesn't re-implement.

## Why it produces better code than a single opencode session

One agent grading its own work is consensus bias. OpenRing structurally prevents that by:

1. **Different model per role.** Architect = Claude. Adversary = Copilot (GPT family). Grinder = Gemini. Different training distributions, genuinely independent failure modes.
2. **Forced rotation.** The Adversary runs on a schedule, not when the Architect decides to ask for a review. The bash loop guarantees it.
3. **Adversary-as-panel (`/ring-adversary-panel`).** Big commits can be reviewed by all three models in parallel; a flaw found by 2+ agents is high-priority.
4. **Voting on hard decisions (`/ring-vote`).** For architecture-level choices, ask all three models and take the majority view with dissenting opinions preserved.
5. **Ollama hot-swap.** When a plan model rate-limits, an Ollama model takes the cycle. The loop doesn't stall waiting on quota reset.

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
cp ~/.openring/AGENTS.md.template ./AGENTS.md         # project blackboard
cp -r ~/.openring/.opencode ./                         # subagents + slash commands
# edit AGENTS.md to describe your project
openring                                               # run the loop
```

## 📁 What gets installed into your project

When you copy the preset into a project, you get:

```
your-project/
├── AGENTS.md                       # Constitution + shared goals. opencode reads this every session.
└── .opencode/
    ├── agent/
    │   ├── architect.md            # Claude — picks next goal, implements
    │   ├── adversary.md            # Copilot — mandatory critic, writes failing tests
    │   └── grinder.md              # Gemini — runs build/tests, smallest-diff fixes
    └── command/
        ├── ring-cycle.md           # One rotation (role picked by openring.sh)
        ├── ring-vote.md            # Fan a question to all 3, tally majority
        └── ring-adversary-panel.md # All 3 review last commits in parallel
```

> The exact directory layout (`.opencode/agent/` vs `.opencode/agents/`, `command/` vs `commands/`) has shifted across opencode versions. If the preset doesn't load, run `opencode --help` and check the paths your version expects, then rename. The preset is plain markdown — there's nothing magic about the folder names.

## 🌀 The loop

`openring.sh` is ~60 lines. It does exactly three things opencode doesn't do on its own:

1. **Schedules cycles.** `while (cycle < MAX_CYCLES)` — picks a role (round-robin with 20% chaos override to Adversary) and runs `opencode run "@<role> proceed"`.
2. **Detects stalls.** After each cycle, compares `git write-tree` hash. If 3 consecutive cycles produce no file changes, it trips a circuit breaker: next cycle is forced to Architect with a prompt to shrink or block the current objective.
3. **Hot-swaps to Ollama.** If opencode exits non-zero (rate limit, credits, auth), the same prompt is re-run through your Ollama model so the cycle isn't wasted.

That's the whole script. Everything else — edits, commits, reading `AGENTS.md`, compressing context — opencode handles.

## ⚙️ Configuration

Env vars, defaults shown:

```bash
ARCHITECT_MODEL="anthropic/claude-sonnet-4-5"
ADVERSARY_MODEL="github-copilot/gpt-5"
GRINDER_MODEL="google/gemini-2.5-pro"
OLLAMA_MODEL=""                    # e.g. "ollama/qwen2.5-coder"
OLLAMA_IN_ROTATION=0               # 1 = include Ollama as a 4th role
MAX_CYCLES=15
CHAOS_RATE=20                      # % chance of a forced Adversary cycle
STALL_LIMIT=3                      # no-progress cycles before breaker trips
COOLDOWN=5                         # seconds between cycles
```

Model IDs shift as vendors ship new versions. Run `opencode models` to see what your logins currently have access to, and override the env vars to match.

## ⚠️ Honest caveats

- **Experimental.** Unattended commit loops produce broken commits sometimes. Run on a scratch branch.
- **Plan limits are real.** Every provider has caps. `MAX_CYCLES=500` will hit them. Ollama fallback is what keeps the loop moving when you do.
- **No ToS evasion.** opencode uses each vendor's sanctioned OAuth flow. OpenRing doesn't disguise traffic, bypass rate limits, or use plans in ways their terms forbid. Check your own plan's terms if unsure.
- **Review your diffs.** The Ring produces candidate code quickly. A human still merges.
- **Preset, not magic.** The intelligence comes from opencode and the models behind it. OpenRing is the clock.

## License

MIT
