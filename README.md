# ⭕ OpenRing

**An unattended multi-model review loop for [opencode](https://opencode.ai). Three peer models take turns in a round-robin; on each turn, the current model either produces forward progress or (with chaos probability) analyzes the previous turn for flaws. `GOAL.md` says when to stop. `AGENTS.md` is the persistent memory. `WHITEBOARD.md` lets you steer from anywhere.**

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Install](https://img.shields.io/badge/install-1_line-brightgreen.svg)
![Status](https://img.shields.io/badge/status-experimental-orange.svg)

Set a goal, walk away, come back to a branch of reviewed commits and a ledger of everything the critics caught.

---

## The shape

```
   ┌─────────── WHITEBOARD.md (remote steering, edit from anywhere) ───────────┐
   │                                                                           │
   │   cycle 1: model 1 ──► cycle 2: model 2 ──► cycle 3: model 3 ──►  ...     │
   │                │                 │                 │                      │
   │                ▼                 ▼                 ▼                      │
   │           produce or         produce or        produce or                 │
   │           analyze (random)   analyze (random)  analyze (random)           │
   │                │                                                          │
   │                ▼                                                          │
   │         AGENTS.md (memory, constitution, critic logs, cycle log)          │
   │                │                                                          │
   │                ▼                                                          │
   │         GOAL.md (checkboxes; all checked → ring stops, awaits human)      │
   └───────────────────────────────────────────────────────────────────────────┘
```

Every turn, the scheduler:
1. Checks `GOAL.md`. All checkboxes done or `GOAL: COMPLETE` seen? **Stop and wait for a human.**
2. Picks the next model in the rotation (round-robin).
3. Rolls the dice. With probability `CHAOS_RATE` (default 33%), this turn is **analyze** mode — the model critiques the previous commit instead of producing forward work. Otherwise it's **produce** mode.
4. Invokes opencode as the builder or critic subagent.
5. Lets opencode edit files, run tests, commit. Appends to the Cycle Log in `AGENTS.md`.
6. Stall check, remote sync, dashboard ping.

That's it. Two roles, three (or four) models, one goal file, one memory file, one whiteboard.

---

## The honest, research-grounded pitch

Most multi-agent coding frameworks fail to beat a well-prompted single agent at equal compute. The literature is clear:

- [Multi-agent debate doesn't reliably outperform self-consistency](https://proceedings.mlr.press/v235/smit24a.html) (ICML 2024).
- [Single-agent matches multi-agent at equal token budget](https://arxiv.org/html/2604.02460v1) on reasoning.
- [MetaGPT's 85.9% HumanEval was vs a badly-underreported 67% GPT-4 baseline](https://github.com/geekan/MetaGPT/issues/418); real single-agent GPT-4 is 86.59%.
- Multi-agent setups consume [4-220× more tokens than single-agent](https://d2jud02ci9yv69.cloudfront.net/2025-04-28-mad-159/blog/mad/).

**But when they do win, the gains are real.** On SWE-bench Verified, [a multi-agent team with a dedicated reviewer hits ~72% vs ~65% single-agent using the same base model](https://aclanthology.org/2025.acl-long.189.pdf) — 7% absolute from structure alone. The mechanism: specialization plus cross-validation from a different perspective.

Single-agent failure modes multi-agent can address (when done right):
- **Degeneration-of-thought** — a model critiquing its own output [repeats its own reasoning errors across iterations](https://arxiv.org/html/2512.20845).
- **Own-family preference** — [models prefer outputs from their own family](https://arxiv.org/html/2506.09443v1); same-model critique rubber-stamps.
- **Self-correction plateau** — [LLMs can't reliably fix their own errors without external feedback](https://proceedings.iclr.cc/paper_files/paper/2024/file/8b4add8b0aa8749d80a34ca5d941c355-Paper-Conference.pdf).

**OpenRing targets those exact conditions.** Heterogeneous model families in the rotation (not the same model three times). Random-but-guaranteed critique (not agent-decided review). Persistent git-backed state (not chat history). Verifiable task shape (tests, constitution, goal file). Long-horizon by design.

On bounded, verifiable, long-horizon coding tasks — bug hunts, test coverage, invariant enforcement, iterative refactors — this is the narrow band where multi-agent actually works, and OpenRing is built to sit in it.

For open-ended greenfield design, a well-prompted single Claude Opus call is often still your best bet. Honest is honest.

Full citations and the failure-mode-to-response mapping: [RESEARCH.md](./RESEARCH.md).

**See it on your own code?** [Benchmark harness](./benchmark):

```bash
./benchmark/benchmark.sh --demo                       # toy Python bug; ~2 min
./benchmark/benchmark.sh --repo ~/my-project \
  --task "Find and fix the race in src/queue" \
  --cycles 20
```

---

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
cp ~/.openring/AGENTS.md.template     ./AGENTS.md
cp ~/.openring/GOAL.md.template       ./GOAL.md
cp ~/.openring/WHITEBOARD.md.template ./WHITEBOARD.md
cp -r ~/.openring/.opencode           ./

# 6. Edit AGENTS.md (constitution) and GOAL.md (checkboxes). Then:
openring
```

## 📁 What lives in your project

```
your-project/
├── AGENTS.md                # constitution + memory (Cycle Log, Known Issues)
├── GOAL.md                  # current objective — stop signal when done
├── WHITEBOARD.md            # remote-control surface, editable from anywhere
└── .opencode/
    ├── agent/
    │   ├── builder.md       # produce mode: make forward progress
    │   └── critic.md        # analyze mode: find flaws, write failing tests
    └── command/
        ├── ring-cycle.md              # manual single turn
        ├── ring-vote.md               # all models vote on a decision
        └── ring-adversary-panel.md    # all models review last commits in parallel
```

> opencode's subagent/command directory name has shifted across versions (`.opencode/agent/` vs `.opencode/agents/`, `command/` vs `commands/`). If the preset doesn't load, rename the folder. File a one-line PR.

## ⚙️ Configuration

OpenRing is **CLI-agnostic**. Each rotation slot is a command template with `{prompt}` substituted at runtime. The defaults invoke opencode with a specific model, but you can point slots at any coding CLI — Claude Code, Codex, Gemini CLI, or anything else that takes a prompt as a final arg.

### Default: opencode

```bash
MODEL_1="anthropic/claude-sonnet-4-5"    # used to build default AGENT_CMD_1
MODEL_2="github-copilot/gpt-5"
MODEL_3="google/gemini-2.5-pro"
```

### Override: native frontier CLIs

```bash
AGENT_CMD_1='claude -p --permission-mode acceptEdits {prompt}'
AGENT_LABEL_1='claude-code'
AGENT_FAMILY_1='anthropic'

AGENT_CMD_2='codex exec {prompt}'
AGENT_LABEL_2='codex'
AGENT_FAMILY_2='openai'

AGENT_CMD_3='gemini --yolo {prompt}'
AGENT_LABEL_3='gemini-cli'
AGENT_FAMILY_3='google'
```

`AGENT_FAMILY_N` is used for the same-family collision warning — set it to something distinct per provider. `{prompt}` is replaced with a shell-quoted form of the current turn's prompt before the command runs. Any CLI that accepts a prompt as its final argument works; for stdin-reading CLIs wrap with `sh -c`.

### Optional local fallback

```bash
OLLAMA_MODEL="ollama/qwen2.5-coder"        # fallback when a plan CLI errors
OLLAMA_CMD=""                              # or set explicit command template
OLLAMA_IN_ROTATION=0                       # 1 = add Ollama as a 4th peer
```

### Loop behavior

```bash
MAX_CYCLES=15
CHAOS_RATE=33                              # % chance a turn is Critic instead of Builder
STALL_LIMIT=2                              # no-tree-change turns → circuit breaker
COOLDOWN=5                                 # seconds between turns
```

### Optional remote

```bash
OPENRING_DASHBOARD_URL=""                  # e.g. https://your-ring.vercel.app
OPENRING_DASHBOARD_TOKEN=""                # matches OPENRING_TOKEN on Vercel
OPENRING_REMOTE_BRANCH=""                  # e.g. "origin main" to pull/push each turn
```

**Single-agent mode:** setting only `AGENT_CMD_1` runs the loop with one agent alternating between build and analyze modes. This loses the core multi-agent mechanism (own-family preference means same-model critique rubber-stamps) — you'll see a startup warning. Use it for testing the scheduler; don't expect multi-agent gains.

## 🎯 Getting the behavior the research predicts

1. **Use different model families in the rotation.** [Models prefer outputs from their own training family](https://arxiv.org/html/2506.09443v1). OpenRing warns loudly at startup if two rotation slots share a provider. Cheapest fix: `MODEL_3="ollama/qwen2.5-coder"` — a local model from a different distribution.
2. **Let it iterate.** The multi-agent advantage shows up on long-horizon work. A 3-turn run won't show it. Run overnight with `MAX_CYCLES=100+`.
3. **Point it at verifiable work.** Bug hunts, test coverage, invariant enforcement, refactors under a test harness. Not blank-page design.
4. **Keep the Constitution tight.** Vague rules give the Critic nothing to enforce. Concrete rules ("all DB access through `storage/`", "no new runtime deps without a line here") become real check-points.
5. **Write a clear `GOAL.md`.** Sharp, bounded checkboxes. When they're all checked, the loop stops and waits for you — which is exactly what you want.
6. **Use the whiteboard to steer.** A one-line whiteboard edit every few hours keeps a long loop on-rails without stopping it.

## 🪧 Remote control (two equivalent paths)

Both write surfaces end up at the same on-disk `WHITEBOARD.md`. Pick whichever fits the moment.

- **Edit the file via git.** GitHub mobile web editor, Cursor, any git client. Commit, push. Loop `git pull`s at the next turn (if `OPENRING_REMOTE_BRANCH` is set). Free, works everywhere.
- **Edit via [the Vercel dashboard](./dashboard).** Deploys a tiny Next.js app with bearer-token auth, Vercel KV, and a textarea. Same file on the other side; loop syncs KV ↔ file at the start of each turn. Live status panel with redacted log tail. Pause / resume / skip / force-critic / stop buttons.

## ⚠️ Honest caveats

- **Experimental.** Unattended commit loops produce broken commits sometimes. Run on a scratch branch.
- **Plan limits are real.** Your subscriptions have caps. `MAX_CYCLES=500` will hit them. Ollama hot-swap keeps the loop moving when you do.
- **No ToS evasion.** opencode uses each vendor's sanctioned OAuth flow. OpenRing doesn't disguise traffic, bypass rate limits, or use plans in ways their terms forbid.
- **Task fit matters.** Bounded verifiable work shines. Open-ended design doesn't. See [RESEARCH.md](./RESEARCH.md).
- **Review your diffs.** The Ring produces candidate code quickly. A human still merges.
- **Preset, not magic.** Intelligence comes from opencode and the models. OpenRing is the clock, the referee, and the steering wheel.

## License

MIT
