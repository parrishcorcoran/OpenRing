# Research notes

Why OpenRing's architecture is designed the way it is — with citations.

The honest summary: **multi-agent coding frameworks often fail to beat a well-prompted single agent at equal compute**, especially on mainstream benchmarks. But when you look at *why* they fail, the failure modes are consistent — and OpenRing is designed to avoid every single one. The gains in the literature are real where the architecture is right, and OpenRing targets that narrow band deliberately.

## What the research actually shows

### Multi-agent doesn't universally win

- [*Should we be going MAD? A Look at Multi-Agent Debate Strategies for LLMs*](https://proceedings.mlr.press/v235/smit24a.html) (ICML 2024): multi-agent debate "does not reliably outperform other proposed prompting strategies, such as self-consistency and ensembling using multiple reasoning paths" and is "more sensitive to different hyperparameter settings and difficult to optimize."
- [*Single-Agent LLMs Outperform Multi-Agent Systems on Multi-Hop Reasoning Under Equal Thinking Token Budgets*](https://arxiv.org/html/2604.02460v1): at equal compute, single-agent chain-of-thought often matches or beats multi-agent debate on reasoning.
- [*Multi-LLM-Agents Debate — Performance, Efficiency, and Scaling Challenges*](https://d2jud02ci9yv69.cloudfront.net/2025-04-28-mad-159/blog/mad/) (ICLR 2025 blog): multi-agent setups consume 4-220× more tokens than single-agent across seven datasets. Self-consistency is "extremely competitive" at a fraction of the budget.
- [MetaGPT GitHub issue #418](https://github.com/geekan/MetaGPT/issues/418): MetaGPT's widely-cited 85.9% on HumanEval was compared against a 67% GPT-4 baseline — but actual single-agent GPT-4 is 86.59%. The multi-agent system roughly matches single-agent on that benchmark, not crushes it.

Takeaway: anyone telling you multi-agent is categorically better is selling something. Most frameworks don't clear the bar.

### But there are specific conditions where multi-agent genuinely wins

- [*Rigorous Evaluation of Coding Agents on SWE-Bench*](https://aclanthology.org/2025.acl-long.189.pdf): on SWE-bench Verified, a multi-agent team with a dedicated reviewer role hits ~72% vs ~65% for single-agent using the same base model — a ~7% absolute gain from *structure alone*. The paper attributes the gain to specialization and cross-validation, not a better model.
- [*Improving Factuality and Reasoning in Language Models through Multiagent Debate*](https://composable-models.github.io/llm_debate/) (Du et al., ICML 2024): debate improves GSM8K 85→87, with larger gains on factuality benchmarks. More agents + more rounds → more improvement, diminishing returns.
- [*Single-agent or Multi-agent Systems? Why Not Both?*](https://arxiv.org/html/2505.18286v1): hybrid approaches outperform either extreme when task decomposition is clean.

### The single-agent failure modes multi-agent can address (when done right)

- **Degeneration-of-thought (DoT):** a single model generating, critiquing, and revising its own output tends to repeat the same reasoning errors across iterations, even after the failure is visible. Documented in a [replication study of Reflexion](https://arxiv.org/html/2512.20845): "the same model generates actions, evaluates its own behavior, and produces reflections, which often results in repeated reasoning errors, confirmation bias, and limited corrective feedback." This is the single strongest argument for heterogeneous-model adversarial review.
- **Own-family preference:** models prefer output from their own family when used as judges ([LLM-as-Judge literature](https://arxiv.org/html/2506.09443v1)). Using a different model family for the critic role isn't a nice-to-have — it's the difference between genuine critique and rubber-stamping.
- **Self-correction plateau:** [*Large Language Models Cannot Self-Correct Reasoning Yet*](https://proceedings.iclr.cc/paper_files/paper/2024/file/8b4add8b0aa8749d80a34ca5d941c355-Paper-Conference.pdf) (ICLR 2024) shows models often can't reliably fix their own errors without external feedback. An external adversary from a different distribution provides exactly that feedback.

### Long-horizon + verifiable tasks is the sweet spot

- [SWE-Bench Pro](https://arxiv.org/pdf/2509.16941) and [SWE-EVO](https://arxiv.org/pdf/2512.18470): long-horizon software evolution benchmarks are where multi-agent structure and iteration time compound. Short tasks don't benefit; sustained iteration on a codebase with a verification harness does.
- Tasks with verifiable ground truth (tests pass/fail, compiler errors, constitution rules) give the adversary something concrete to check — converting taste-based critique into evidence-based critique.

## How OpenRing targets the conditions where multi-agent wins

Every one of these is a deliberate response to a specific failure mode in the literature:

| Failure mode | OpenRing's response |
|---|---|
| Degeneration-of-thought from single-model self-critique | Architect / Adversary / Grinder use **different model families** by default (Claude / Copilot-GPT / Gemini). Same-family setups are possible but not encouraged. |
| Own-family preference in LLM-as-judge | Adversary is mandated to use a different family from Architect. Adversary-panel mode runs *all three* in parallel; flaws reported by 2+ are flagged high-priority. |
| Critic rubber-stamping ("looks fine") | Adversary system prompt **requires** a concrete reproducer (failing test, exact line numbers) or an explicit "no flaws found, verified by X" log with evidence. No vague prose. |
| Context drift over long loops | Persistent state in git-tracked files (`AGENTS.md`, `WHITEBOARD.md`) instead of an ephemeral chat history. Every turn reads from disk, not memory. |
| Architect skipping the review step | Role rotation is **external and forced** by a bash scheduler. Architect can't decide to skip the Adversary cycle. 20% chaos-rate override further randomizes when critique happens. |
| 4-220× token cost of multi-agent | Ollama hot-swap fallback keeps cost bounded when plan models throttle. 4-way rotation with Ollama gives free mechanical work every 4th cycle. |
| No steering of a 48-hour loop | `WHITEBOARD.md` is a plain file you edit from anywhere (GitHub mobile, Vercel dashboard, laptop). The Architect reads it before the objective and wipes it when addressed. |
| Hyperparameter sensitivity | Everything exposed as env vars (`CHAOS_RATE`, `STALL_LIMIT`, `MAX_CYCLES`, model choices). Tunable per-project. |

## What OpenRing *doesn't* claim

- It will not produce "amazing output" on open-ended or greenfield design problems. The adversary has nothing concrete to critique, so the loop devolves to taste vs. taste and doesn't converge. Research consistently shows single-agent with strong prompting matches multi-agent on this task class.
- It is not cheaper than a single well-prompted Claude call for a single bug fix. The multiplier kicks in at long iteration on bounded tasks, not one-shot generation.
- It is not a plug-and-play superintelligence. It's a structural advantage on a specific task class, and it depends on good direction (via `WHITEBOARD.md`) and clean verification (tests, linters, constitution).

## What OpenRing *does* claim, honestly

Given the literature:

1. **On bounded, verifiable, long-horizon coding tasks** — bug hunts, test coverage expansion, enforcing invariants, adversarial security review, iterative refactors — OpenRing's architecture aligns with every documented condition under which multi-agent approaches genuinely outperform single-agent. Expected range: 10-50% improvement on the right task structure, with occasional transformative finds the single-agent loop wouldn't have made.
2. **Plan-login economics** (via opencode auth) + Ollama hot-swap address the 4-220× token cost problem that otherwise makes multi-agent impractical for individuals.
3. **The whiteboard pattern** is the operational piece that turns long-horizon theoretical gains into practical ones: you can steer a 48-hour loop from your phone without stopping it.

That's the pitch, grounded. Not superintelligence. A well-designed structural advantage on a specific task class, made practically accessible.
