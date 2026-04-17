# Benchmark harness

A side-by-side comparison between a single-agent opencode run and OpenRing on the same task.

**This is not a scientific benchmark.** It's a practical "does the Ring actually do better on *my* problem?" tool. For rigorous multi-agent evaluation, use [SWE-bench Verified](https://openai.com/index/introducing-swe-bench-verified/) or [SWE-Bench Pro](https://arxiv.org/pdf/2509.16941). Those test on hundreds of real GitHub issues with careful controls.

This harness runs *one task, once*. LLMs are stochastic; averaging over 3-5 runs is the minimum before drawing any conclusions.

## Quick start

Run the built-in demo (a tiny Python bump allocator with intentional bugs and failing tests):

```bash
./benchmark/benchmark.sh --demo
```

That will:

1. Create a scratch workdir.
2. Clone the demo fixture into two identical worktrees.
3. Run single-agent opencode in one with the task "make tests pass."
4. Run OpenRing in the other for 10 cycles.
5. Run the test suite against each end state.
6. Print a summary: did tests pass, how many commits, how many lines changed, wall-clock time.

## Against your own codebase

```bash
./benchmark/benchmark.sh \
  --repo /path/to/your/project \
  --task "Find and fix the race condition in src/queue. Add a failing test first, then fix it." \
  --cycles 20 \
  --test-cmd "cargo test --quiet"
```

Both runs happen in *copies* of your repo — your source is never touched.

## What this is good for

- **Sanity-checking your OpenRing config.** If the Ring does worse than a single-agent on your task, your models are probably same-family (check for the startup warning) or your Constitution is too vague.
- **Feeling the multiplier.** On bounded debugging tasks, you'll usually see the Ring commit more, touch more lines, and catch edge cases the single-agent missed (because the Adversary was forced to look for them).
- **Getting comfortable with the loop** before you run it unattended on real work.

## What this is *not* good for

- **Headline numbers.** One run tells you almost nothing statistically.
- **Cost comparisons.** OpenRing runs more agent turns, which will use more tokens. The question isn't "is it cheaper per task" — it's "is the better output worth the cost, on this class of task."
- **Open-ended design tasks.** The research is pretty clear: multi-agent doesn't beat single-agent at blank-page work. Don't benchmark creative tasks; benchmark bug fixes, test coverage, and refactors under a test harness. That's where the mechanism actually works.

## Interpreting results

A good Ring run on a bounded debugging task looks like:

```
baseline   tests=FAIL  commits=1   loc=12    wall=45s
ring       tests=PASS  commits=4   loc=31    wall=280s
```

The Ring does more work, runs longer, and catches cases the single-shot missed. That's the expected shape when the architecture is configured right.

A *bad* Ring run looks like:

```
baseline   tests=PASS  commits=1   loc=8     wall=30s
ring       tests=FAIL  commits=9   loc=140   wall=420s
```

That's churn without convergence. Usually it means: same-family Architect/Adversary (no real critique), or a Constitution so vague the Adversary has nothing to enforce, or no tests to anchor the Adversary's work.
