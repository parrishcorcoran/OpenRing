# SWE-bench adapter for OpenRing

Runs OpenRing (and optionally a single-agent baseline) against [SWE-bench Verified](https://openai.com/index/introducing-swe-bench-verified/) or [SWE-bench Lite](https://www.swebench.com/lite.html) tasks, producing predictions in the format the official [swebench](https://github.com/SWE-bench/SWE-bench) scorer expects.

**Generation is here. Evaluation is the official swebench harness.** This adapter only produces predictions (patches). To score them, you use `pip install swebench` and `python -m swebench.harness.run_evaluation`. That half runs in Docker containers for reproducibility.

## What this adapter does per task

1. Clones the task's upstream repo at its `base_commit`.
2. Applies the task's `test_patch` (adds the failing tests for the bug).
3. Writes a task-specific `AGENTS.md` (Constitution + the issue's `problem_statement`) and `GOAL.md` (single checkbox: "make FAIL_TO_PASS tests pass without breaking PASS_TO_PASS tests").
4. Runs `openring.sh` in the task dir with whatever `MAX_CYCLES` you pass.
5. Captures `git diff base_commit HEAD` as the prediction.
6. Appends to `predictions.jsonl` in swebench format.
7. Optional: runs the same task through single-agent opencode as a baseline, writes to `baseline_predictions.jsonl`.

## Time and rate limits, up front

**If you're running via plan logins (Claude Max, Copilot Pro, Gemini Advanced), token cost isn't the variable — wall time and rate-limit throttling are.** Rough estimates for a default 3-model OpenRing config at `MAX_CYCLES=15` per task:

| Task set | Tasks | Rough wall time | Notes |
|---|---|---|---|
| Lite subset | 10   | 1-2 h    | Entry point. Prove the adapter. Rarely hits rate limits. |
| Lite full   | 300  | 12-24 h  | Will hit per-hour caps on at least one provider. Ollama hot-swap covers. |
| Verified    | 500  | 24-48 h  | Plan to spread across 1-2 nights, or spin up a cloud box. |

Ollama fallback is your best friend here. When Claude Max hits its usage window or Copilot Pro throttles, `OLLAMA_MODEL=ollama/qwen2.5-coder` keeps that task moving on local hardware — the task still completes, just with a lower-quality turn mixed in. Set it and forget it.

Wall-time variance per task is huge. A well-scoped bug fix converges in 3-4 cycles; an obscure test failure can eat the full `MAX_CYCLES`. The total time is dominated by the long-tail tasks, not the average.

## Requirements

- All of OpenRing's normal requirements (opencode, logged-in providers, git).
- Python 3.10+ with `pip install datasets` (to load tasks from HuggingFace).
- ~50 GB free disk if running the full Verified set (repos get cached).
- Optional: `jq` for prettier output.

## Quick start (10-task Lite sanity check)

```bash
cd /path/to/OpenRing
pip install datasets

./benchmark/swe-bench/run.sh \
  --task-set lite \
  --n-tasks 10 \
  --max-cycles 12 \
  --output-dir ~/openring-swebench-run-1
```

When it finishes:

```bash
ls ~/openring-swebench-run-1/
#   predictions.jsonl          — OpenRing's patches, swebench format
#   baseline_predictions.jsonl  — single-agent baseline (if --baseline was passed)
#   per-task/<instance_id>/    — one dir per task with AGENTS.md, GOAL.md, logs, diff
#   summary.txt                — tasks attempted, tasks with non-empty patches, wall time
```

## Scoring the predictions

This adapter does *not* score. Use the official SWE-bench harness:

```bash
pip install swebench
python -m swebench.harness.run_evaluation \
  --dataset_name princeton-nlp/SWE-bench_Lite \
  --predictions_path ~/openring-swebench-run-1/predictions.jsonl \
  --max_workers 4 \
  --run_id openring-lite-1
```

That runs each prediction's patch against the real test suite inside a Docker container. Output: pass/fail per task, aggregated resolution rate.

## The comparison that actually matters

If you're running OpenRing with three frontier coding CLIs (Claude Code + Codex + Gemini CLI), the honest question isn't "does OpenRing beat opencode-with-one-model?" — it's **"does OpenRing beat each frontier CLI running alone on the same tasks?"** That's the benchmark that isolates what the orchestration adds.

The runner supports repeatable `--baseline-cli LABEL=CMD_TEMPLATE` flags. Each baseline runs on every task, producing its own predictions file for head-to-head scoring:

```bash
./benchmark/swe-bench/run.sh \
  --task-set lite \
  --n-tasks 50 \
  --max-cycles 15 \
  --baseline-cli "claude=claude -p --permission-mode acceptEdits {prompt}" \
  --baseline-cli "codex=codex exec {prompt}" \
  --baseline-cli "gemini=gemini --yolo {prompt}"
```

Output:

```
~/swebench-output/
├── predictions.jsonl          # OpenRing (all 3 rotating)
├── baseline-claude.jsonl      # Claude Code alone
├── baseline-codex.jsonl       # Codex alone
├── baseline-gemini.jsonl      # Gemini CLI alone
└── per-task/<instance_id>/    # all logs + patches per task
```

Then score each file:

```bash
for f in predictions baseline-claude baseline-codex baseline-gemini; do
  python -m swebench.harness.run_evaluation \
    --dataset_name princeton-nlp/SWE-bench_Lite \
    --predictions_path ~/swebench-output/${f}.jsonl \
    --run_id ${f}-$(date +%Y%m%d)
done
```

What you're looking for in the results:

- **OpenRing > every individual CLI** — orchestration is genuinely adding value.
- **OpenRing ≈ best individual CLI** — orchestration is matching the strongest member, so you're paying ~3× wall time for parity. Worth it if reliability matters, not if raw pass rate is the only metric.
- **OpenRing < best individual CLI** — rotation or critic prompts are hurting more than helping. Check same-family collisions, check MAX_CYCLES is high enough, consider whether the specialty subagents are misfiring.

Research expectation (from [RESEARCH.md](../../RESEARCH.md)): on SWE-bench Verified, a well-structured multi-agent with a different-model reviewer beats single-agent by ~7% absolute at the same base model. With three *different* frontier CLIs in rotation, the structural advantage should be at least that much, plus whatever each CLI's native specialty contributes. On Lite, signal-to-noise is tighter; treat Lite as a directional check and Verified as the real measurement.

If you get worse-than-baseline numbers, the most likely causes are (in order):
1. **Same-family slots** — check `AGENT_FAMILY_N` values and the startup warning.
2. **`MAX_CYCLES` too low** — each task needs enough cycles for at least one critic round. Try 15-20.
3. **The baseline CLIs have very different default behaviors around commits** — some commit aggressively, some wait for confirmation. If a CLI doesn't commit its fix, the patch extraction will be empty. Check the per-task logs.

## Flags

```
--task-set        verified | lite             (default: lite)
--n-tasks         N (random sample) | all     (default: 10)
--task-ids        comma-separated instance_ids (overrides --n-tasks)
--max-cycles      passed through to openring.sh (default: 15)
--output-dir      where to write everything    (default: ./swebench-output)
--baseline-cli    LABEL=CMD_TEMPLATE (repeatable); runs single-CLI baseline
                  on every task. CMD_TEMPLATE uses {prompt}.
--resume          skip tasks with existing predictions in output-dir
```

## Limits I won't pretend don't exist

- **One run is not statistically meaningful.** LLM outputs are stochastic. For publication-worthy numbers, run the same config 3-5 times and report means + variance.
- **SWE-bench has known issues.** Some tasks have leaked to training data; some have flaky tests; some are ambiguous. SWE-bench Verified was curated to fix this but isn't perfect. Treat absolute numbers as ball-park; relative comparisons (OpenRing vs baseline on the same tasks, same runs) are more reliable.
- **Plan rate limits will skew results if the loop hits them late.** Ollama hot-swap keeps it moving but hot-swap cycles produce different work than the planned model would have. Track how many cycles per task used fallback; flag any task with >30% fallback cycles as "degraded."
- **`MAX_CYCLES` is a blunt budget.** Some tasks converge in 3 cycles, some need 40. A fixed cap under-serves both. For a real comparison, match cycle budget between OpenRing and baseline, not "single opencode call" (which has no cycle concept). Give the baseline a similar number of retries to match the total compute it gets.
