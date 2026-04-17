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

## Comparing OpenRing vs baseline honestly

Run with `--baseline` to also generate single-agent predictions using whatever you set as `--baseline-model` (default: your `ARCHITECT_MODEL`). Then score both and compare:

```bash
python -m swebench.harness.run_evaluation \
  --predictions_path ~/openring-swebench-run-1/predictions.jsonl \
  --run_id openring

python -m swebench.harness.run_evaluation \
  --predictions_path ~/openring-swebench-run-1/baseline_predictions.jsonl \
  --run_id baseline
```

What the research predicts (from [RESEARCH.md](../../RESEARCH.md)): on a task class with verifiable ground truth and long horizons like SWE-bench, multi-agent with a reviewer typically hits ~7% absolute higher resolution rate than single-agent with the same base model. OpenRing's rotation + forced critique should sit in that range, maybe better if the specialty subagents and multi-round critique pay off.

If you get worse-than-baseline numbers, the most likely causes are (in order):
1. **Same-family models in rotation** — check the startup warning wasn't suppressed.
2. **`MAX_CYCLES` too low** — each task needs enough cycles to see a critic round after the builder. Try 15-20.
3. **Constitution is vague** — the task-template Constitution is fine, but if you modified it, make sure rules are concrete.

## Flags

```
--task-set        verified | lite             (default: lite)
--n-tasks         N (random sample) | all     (default: 10)
--task-ids        comma-separated instance_ids (overrides --n-tasks)
--max-cycles      passed through to openring.sh (default: 15)
--output-dir      where to write everything    (default: ./swebench-output)
--baseline        also generate single-agent predictions
--baseline-model  which model to use for baseline (default: $ARCHITECT_MODEL)
--resume          skip tasks with existing predictions in output-dir
```

## Limits I won't pretend don't exist

- **One run is not statistically meaningful.** LLM outputs are stochastic. For publication-worthy numbers, run the same config 3-5 times and report means + variance.
- **SWE-bench has known issues.** Some tasks have leaked to training data; some have flaky tests; some are ambiguous. SWE-bench Verified was curated to fix this but isn't perfect. Treat absolute numbers as ball-park; relative comparisons (OpenRing vs baseline on the same tasks, same runs) are more reliable.
- **Plan rate limits will skew results if the loop hits them late.** Ollama hot-swap keeps it moving but hot-swap cycles produce different work than the planned model would have. Track how many cycles per task used fallback; flag any task with >30% fallback cycles as "degraded."
- **`MAX_CYCLES` is a blunt budget.** Some tasks converge in 3 cycles, some need 40. A fixed cap under-serves both. For a real comparison, match cycle budget between OpenRing and baseline, not "single opencode call" (which has no cycle concept). Give the baseline a similar number of retries to match the total compute it gets.
