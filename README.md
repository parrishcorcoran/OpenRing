# ⭕ OpenRing

**A multi-agent orchestrator that routes coding work across the CLI tools you already have installed.**

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Install](https://img.shields.io/badge/install-1_line-brightgreen.svg)
![Status](https://img.shields.io/badge/status-experimental-orange.svg)

OpenRing is an open-source orchestration layer for autonomous coding loops. It coordinates the `claude`, `gh copilot`, and `ollama` CLIs as three distinct cognitive roles — **Architect**, **Adversary**, and **Grinder** — driven by a shared on-disk state (`CONSTITUTION.md`, `RING_GOALS.md`) so the agents converge instead of drifting.

> ⚠️ **Terms of Service notice.** OpenRing calls whatever CLI tools you point it at. You are responsible for using those tools within the terms of service of their providers. Anthropic, GitHub, and other vendors generally prohibit unattended/headless automation on interactive subscription plans. If you want a 24/7 autonomous loop, use API billing, a self-hosted model (Ollama), or a plan whose terms permit it. OpenRing does not and will not ship code designed to evade rate limits or disguise automated traffic as human traffic.

## ✨ Why OpenRing?

Single-agent coding loops suffer from **consensus bias**: the model that wrote the code is the same model grading the code, so it rubber-stamps its own work. OpenRing breaks that loop by assigning *structurally adversarial* roles to different CLIs and enforcing a shared written state between cycles.

- **🧠 Architect** — deep reasoning and planning. Typically the `claude` CLI.
- **🛡️ Adversary** — mandated critic. Required to find at least one real flaw per Chaos Round.
- **⚙️ Grinder** — low-level execution, compile loops, lint fixes. Local model via `ollama`.

## 🧠 Why separate roles produce better code

Role separation is not about model strength; it is about *incentive*. When one process is contractually obligated to attack the previous process's work, you get genuine iteration instead of self-congratulation. The Constitution + Goals files act as a shared blackboard, so each turn starts from written-down state rather than a thread of chat that degrades over time.

This does not magically produce "superintelligence." It produces a modest but real improvement: fewer hallucinated APIs, fewer silent requirement drops, faster convergence on compiling code. That is the honest pitch.

## 🚀 Quick Start

Prerequisites — install whichever of these you have access to:

- [`claude`](https://docs.claude.com/en/docs/claude-code) — Claude Code CLI
- [`gh`](https://cli.github.com/) + [`gh copilot`](https://docs.github.com/en/copilot/github-copilot-in-the-cli) extension
- [`ollama`](https://ollama.com/) with a local coder model (e.g. `deepseek-coder-v2`, `qwen2.5-coder`)

```bash
git clone https://github.com/yourusername/openring.git
cd openring
chmod +x openring.sh
./openring.sh
```

OpenRing will skip any role whose CLI is not installed, so a subset works fine for trying it out.

## 🌀 How it works

1. Each cycle picks a role from the round-robin (`Architect → Adversary → Grinder`).
2. With probability `CHAOS_RATE` the role is overridden to **Adversary**.
3. The agent reads `CONSTITUTION.md` (hard rules) and `RING_GOALS.md` (shared checklist + known issues).
4. The agent edits files, commits, and updates `RING_GOALS.md` with what it did and any new issues.
5. A **Circuit Breaker** watches for stalemates and forces resolution if the loop stops making forward progress.
6. A **Context Summarizer** periodically compresses `RING_GOALS.md` so the files don't grow without bound.

## 🔒 The Constitution

`CONSTITUTION.md` is the project-specific firewall. Every agent reads it every turn. Put your non-negotiable architectural decisions here (language choice, memory rules, public API shape) so long-running loops don't hallucinate them away on cycle 47.

## ⚠️ Limits and honest caveats

- **This is experimental.** Autonomous commit loops can and will produce broken commits. Run on a scratch branch.
- **No magic.** OpenRing is ~150 lines of bash. It is an orchestrator, not a model.
- **Cost is not zero.** If you point it at a paid API, it spends money. If you point it at an interactive subscription, see the ToS notice above.
- **Review your diffs.** The Ring is a tool for producing candidate code quickly. A human still merges.

## License

MIT
