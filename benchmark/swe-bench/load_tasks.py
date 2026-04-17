#!/usr/bin/env python3
"""Load SWE-bench tasks from HuggingFace and emit one JSON line per task.

Called by run.sh. Keeps the bash driver simple.

Usage:
  python3 load_tasks.py --task-set verified --n-tasks 10
  python3 load_tasks.py --task-set lite --task-ids a,b,c
  python3 load_tasks.py --task-set lite --n-tasks all
"""

from __future__ import annotations

import argparse
import json
import random
import sys


DATASETS = {
    "verified": "princeton-nlp/SWE-bench_Verified",
    "lite": "princeton-nlp/SWE-bench_Lite",
    "full": "princeton-nlp/SWE-bench",
}

REQUIRED_FIELDS = [
    "instance_id",
    "repo",
    "base_commit",
    "problem_statement",
    "test_patch",
    "FAIL_TO_PASS",
    "PASS_TO_PASS",
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--task-set", choices=DATASETS.keys(), default="lite")
    ap.add_argument("--n-tasks", default="10", help='integer or "all"')
    ap.add_argument("--task-ids", default="", help="comma-separated instance_ids")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    try:
        from datasets import load_dataset
    except ImportError:
        print("error: 'datasets' not installed. Run: pip install datasets", file=sys.stderr)
        return 2

    ds = load_dataset(DATASETS[args.task_set], split="test")

    rows = list(ds)
    if args.task_ids:
        wanted = {x.strip() for x in args.task_ids.split(",") if x.strip()}
        rows = [r for r in rows if r["instance_id"] in wanted]
        missing = wanted - {r["instance_id"] for r in rows}
        if missing:
            print(f"warning: task-ids not found in {args.task_set}: {sorted(missing)}", file=sys.stderr)
    elif args.n_tasks != "all":
        n = int(args.n_tasks)
        random.seed(args.seed)
        random.shuffle(rows)
        rows = rows[:n]

    for row in rows:
        # Keep only the fields we actually use downstream — dataset rows can be large.
        out = {k: row[k] for k in REQUIRED_FIELDS if k in row}
        out["FAIL_TO_PASS"] = _as_list(out.get("FAIL_TO_PASS", []))
        out["PASS_TO_PASS"] = _as_list(out.get("PASS_TO_PASS", []))
        print(json.dumps(out))

    return 0


def _as_list(v):
    # Dataset sometimes stores these as JSON-encoded strings; normalize to list.
    if isinstance(v, list):
        return v
    if isinstance(v, str):
        try:
            parsed = json.loads(v)
            if isinstance(parsed, list):
                return parsed
        except json.JSONDecodeError:
            pass
    return []


if __name__ == "__main__":
    sys.exit(main())
