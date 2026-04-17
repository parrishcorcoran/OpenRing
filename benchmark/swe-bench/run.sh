#!/usr/bin/env bash
# Run OpenRing against a SWE-bench task set. Outputs predictions.jsonl in the
# format the official swebench evaluator expects. Does NOT score — use
# `python -m swebench.harness.run_evaluation` for that.

set -uo pipefail

# ---------- Args ----------
TASK_SET="lite"
N_TASKS="10"
TASK_IDS=""
MAX_CYCLES="${MAX_CYCLES:-15}"
OUTPUT_DIR="./swebench-output"
BASELINE=0
BASELINE_MODEL="${BASELINE_MODEL:-${ARCHITECT_MODEL:-${MODEL_1:-anthropic/claude-sonnet-4-5}}}"
RESUME=0

while [ $# -gt 0 ]; do
  case "$1" in
    --task-set)       TASK_SET="$2"; shift 2 ;;
    --n-tasks)        N_TASKS="$2"; shift 2 ;;
    --task-ids)       TASK_IDS="$2"; shift 2 ;;
    --max-cycles)     MAX_CYCLES="$2"; shift 2 ;;
    --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
    --baseline)       BASELINE=1; shift ;;
    --baseline-model) BASELINE_MODEL="$2"; shift 2 ;;
    --resume)         RESUME=1; shift ;;
    -h|--help)        sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")" || OUTPUT_DIR="$PWD/$(basename "$OUTPUT_DIR")"

command -v opencode >/dev/null 2>&1 || { echo "❌ opencode not found"; exit 1; }
command -v python3  >/dev/null 2>&1 || { echo "❌ python3 not found"; exit 1; }
command -v git      >/dev/null 2>&1 || { echo "❌ git not found"; exit 1; }

mkdir -p "$OUTPUT_DIR/per-task"
PREDS="$OUTPUT_DIR/predictions.jsonl"
BASE_PREDS="$OUTPUT_DIR/baseline_predictions.jsonl"
SUMMARY="$OUTPUT_DIR/summary.txt"
[ "$RESUME" = 1 ] || : > "$PREDS"
[ "$RESUME" = 1 ] || [ "$BASELINE" = 0 ] || : > "$BASE_PREDS"

START_TS=$(date +%s)
echo "🏁 SWE-bench run: task_set=$TASK_SET  n=$N_TASKS  max_cycles=$MAX_CYCLES  output=$OUTPUT_DIR"
echo "   predictions → $PREDS"
[ "$BASELINE" = 1 ] && echo "   baseline    → $BASE_PREDS  (model: $BASELINE_MODEL)"

# ---------- Fetch tasks ----------
TASKS_JSONL="$OUTPUT_DIR/tasks.jsonl"
python3 "$HERE/load_tasks.py" \
  --task-set "$TASK_SET" \
  --n-tasks "$N_TASKS" \
  --task-ids "$TASK_IDS" \
  > "$TASKS_JSONL" || { echo "❌ failed to load tasks"; exit 1; }

N_LOADED=$(wc -l < "$TASKS_JSONL" | tr -d ' ')
echo "📦 Loaded $N_LOADED task(s)."

# ---------- Per-task helpers ----------
already_done() {
  local instance_id="$1" preds="$2"
  [ -f "$preds" ] && grep -qF "\"instance_id\": \"$instance_id\"" "$preds"
}

write_agents_md() {
  local task_dir="$1" instance_id="$2" problem="$3"
  cat > "$task_dir/AGENTS.md" <<EOF
# AGENTS.md — SWE-bench task $instance_id

## Constitution
- Make the FAIL_TO_PASS tests pass without breaking any PASS_TO_PASS tests.
- Do not edit tests. Do not delete tests. Do not disable tests.
- Do not stub functions to fake-pass tests.
- Smallest diff that works.
- No new runtime dependencies unless the issue explicitly requires one.
- If you cannot resolve this task in the cycle budget, log the remaining blocker under Known Issues with the exact error and stop.

## Problem statement (from upstream issue)

$problem

## Known Issues
_(populated by Critic turns)_

## Cycle Log
- [cycle 0] bootstrap: SWE-bench task $instance_id initialized.

## Archive
EOF
}

write_goal_md() {
  local task_dir="$1" fail_list="$2"
  {
    echo "# GOAL"
    echo ""
    echo "## Current Objective"
    echo "Resolve the upstream issue such that all FAIL_TO_PASS tests pass and no PASS_TO_PASS tests regress."
    echo ""
    echo "## Checkboxes"
    echo "- [ ] All FAIL_TO_PASS tests pass."
    echo "- [ ] No PASS_TO_PASS tests regress."
    echo ""
    echo "## FAIL_TO_PASS (must pass after your patch)"
    if [ -n "$fail_list" ]; then
      while IFS= read -r t; do [ -n "$t" ] && echo "- \`$t\`"; done <<< "$fail_list"
    else
      echo "_(list unavailable — see test_patch for the failing tests)_"
    fi
  } > "$task_dir/GOAL.md"
}

setup_task_dir() {
  local task_dir="$1" repo="$2" base_commit="$3" test_patch="$4"
  rm -rf "$task_dir/repo"
  mkdir -p "$task_dir/repo"
  git clone --quiet "https://github.com/$repo.git" "$task_dir/repo" || return 1
  git -C "$task_dir/repo" checkout --quiet "$base_commit" || return 1
  git -C "$task_dir/repo" config user.email "bench@openring.local"
  git -C "$task_dir/repo" config user.name  "OpenRing SWE-bench"
  printf '%s' "$test_patch" > "$task_dir/test_patch.diff"
  # Apply the test patch so the failing tests are present. Use --check first; skip if it fails.
  ( cd "$task_dir/repo" && git apply --check "../test_patch.diff" 2>/dev/null && git apply "../test_patch.diff" && \
      git add -A && git commit -q -m "bench: apply test_patch" ) || {
    echo "   ⚠  test_patch would not apply cleanly; skipping task"
    return 1
  }
  return 0
}

extract_patch() {
  # Patch = diff from the original base_commit (before test_patch) to current HEAD,
  # MINUS the test_patch itself. swebench expects just the "fix" part.
  local task_dir="$1" base_commit="$2"
  local full_diff
  full_diff=$(git -C "$task_dir/repo" diff "$base_commit" HEAD)
  # Subtract the test_patch by reverse-applying it to the diff. Simpler approach:
  # diff from the "after test_patch" commit (HEAD~N where N is the number of commits since)
  # to HEAD. The test_patch commit is the first after base_commit, so diff its parent.
  local test_patch_sha
  test_patch_sha=$(git -C "$task_dir/repo" rev-list --reverse "$base_commit"..HEAD | head -n 1)
  if [ -n "$test_patch_sha" ]; then
    git -C "$task_dir/repo" diff "$test_patch_sha" HEAD
  else
    echo "$full_diff"
  fi
}

json_esc() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'; }

append_prediction() {
  local out="$1" instance_id="$2" model_name="$3" patch="$4"
  local patch_json; patch_json=$(printf '%s' "$patch" | json_esc)
  # swebench format: {"instance_id": "...", "model_name_or_path": "...", "model_patch": "..."}
  printf '{"instance_id": "%s", "model_name_or_path": "%s", "model_patch": %s}\n' \
    "$instance_id" "$model_name" "$patch_json" >> "$out"
}

# ---------- Main loop ----------
TASKS_ATTEMPTED=0
OPENRING_NONEMPTY=0
BASELINE_NONEMPTY=0

while IFS= read -r task_json; do
  [ -z "$task_json" ] && continue
  TASKS_ATTEMPTED=$((TASKS_ATTEMPTED + 1))

  INSTANCE_ID=$(printf '%s' "$task_json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["instance_id"])')
  REPO=$(printf '%s' "$task_json"        | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["repo"])')
  BASE_COMMIT=$(printf '%s' "$task_json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["base_commit"])')
  PROBLEM=$(printf '%s' "$task_json"     | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["problem_statement"])')
  TEST_PATCH=$(printf '%s' "$task_json"  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["test_patch"])')
  FAIL_LIST=$(printf '%s' "$task_json"   | python3 -c 'import json,sys;d=json.load(sys.stdin);
for t in d.get("FAIL_TO_PASS",[]): print(t)' <<< "$task_json" 2>/dev/null)

  echo ""
  echo "════════ Task $TASKS_ATTEMPTED / $N_LOADED: $INSTANCE_ID ════════"

  if [ "$RESUME" = 1 ] && already_done "$INSTANCE_ID" "$PREDS"; then
    echo "   (already have prediction; skipping)"
    continue
  fi

  TASK_DIR="$OUTPUT_DIR/per-task/$INSTANCE_ID"
  mkdir -p "$TASK_DIR"
  setup_task_dir "$TASK_DIR" "$REPO" "$BASE_COMMIT" "$TEST_PATCH" || continue
  write_agents_md "$TASK_DIR/repo" "$INSTANCE_ID" "$PROBLEM"
  write_goal_md   "$TASK_DIR/repo" "$FAIL_LIST"

  # Copy the opencode preset + whiteboard into the task's repo dir.
  cp -r "$REPO_ROOT/.opencode"              "$TASK_DIR/repo/" 2>/dev/null || true
  cp "$REPO_ROOT/WHITEBOARD.md.template"    "$TASK_DIR/repo/WHITEBOARD.md" 2>/dev/null || true

  # --- OpenRing run ---
  TASK_START=$(date +%s)
  (
    cd "$TASK_DIR/repo"
    MAX_CYCLES="$MAX_CYCLES" COOLDOWN=1 "$REPO_ROOT/openring.sh" 2>&1 | tee "$TASK_DIR/openring.log"
  ) || echo "   (openring exited non-zero)"
  TASK_END=$(date +%s)

  OR_PATCH=$(extract_patch "$TASK_DIR" "$BASE_COMMIT" 2>/dev/null || echo "")
  printf '%s' "$OR_PATCH" > "$TASK_DIR/openring.patch"
  if [ -s "$TASK_DIR/openring.patch" ]; then
    OPENRING_NONEMPTY=$((OPENRING_NONEMPTY + 1))
  fi
  append_prediction "$PREDS" "$INSTANCE_ID" "openring-${TASK_SET}" "$OR_PATCH"
  echo "   ✅ openring: wall=$((TASK_END - TASK_START))s  patch_bytes=$(wc -c < "$TASK_DIR/openring.patch" | tr -d ' ')"

  # --- Baseline run (optional) ---
  if [ "$BASELINE" = 1 ]; then
    BASE_DIR="$TASK_DIR/baseline-repo"
    rm -rf "$BASE_DIR"
    git clone --quiet "https://github.com/$REPO.git" "$BASE_DIR" || continue
    git -C "$BASE_DIR" checkout --quiet "$BASE_COMMIT"
    git -C "$BASE_DIR" config user.email "bench@openring.local"
    git -C "$BASE_DIR" config user.name  "OpenRing SWE-bench"
    ( cd "$BASE_DIR" && git apply "../test_patch.diff" && git add -A && git commit -q -m "bench: apply test_patch" ) || continue

    BASE_START=$(date +%s)
    (
      cd "$BASE_DIR"
      opencode run --model "$BASELINE_MODEL" \
        "Resolve the following issue by editing the code so the FAIL_TO_PASS tests pass and PASS_TO_PASS tests still pass. Do not edit tests. Do not stub. Commit your changes. Problem:

$PROBLEM" \
        2>&1 | tee "$TASK_DIR/baseline.log"
    ) || echo "   (baseline exited non-zero)"
    BASE_END=$(date +%s)

    # Baseline patch = diff from base_commit+test_patch to HEAD
    BASE_PATCH_SHA=$(git -C "$BASE_DIR" rev-list --reverse "$BASE_COMMIT"..HEAD | head -n 1)
    if [ -n "$BASE_PATCH_SHA" ]; then
      BASE_PATCH=$(git -C "$BASE_DIR" diff "$BASE_PATCH_SHA" HEAD)
    else
      BASE_PATCH=""
    fi
    printf '%s' "$BASE_PATCH" > "$TASK_DIR/baseline.patch"
    [ -s "$TASK_DIR/baseline.patch" ] && BASELINE_NONEMPTY=$((BASELINE_NONEMPTY + 1))
    append_prediction "$BASE_PREDS" "$INSTANCE_ID" "baseline-$BASELINE_MODEL" "$BASE_PATCH"
    echo "   ✅ baseline: wall=$((BASE_END - BASE_START))s  patch_bytes=$(wc -c < "$TASK_DIR/baseline.patch" | tr -d ' ')"
  fi

done < "$TASKS_JSONL"

END_TS=$(date +%s)
WALL=$((END_TS - START_TS))

{
  echo "SWE-bench adapter run summary"
  echo "  task_set:          $TASK_SET"
  echo "  tasks_loaded:      $N_LOADED"
  echo "  tasks_attempted:   $TASKS_ATTEMPTED"
  echo "  openring_patches:  $OPENRING_NONEMPTY (non-empty)"
  [ "$BASELINE" = 1 ] && echo "  baseline_patches:  $BASELINE_NONEMPTY (non-empty)"
  echo "  max_cycles:        $MAX_CYCLES"
  echo "  wall_time_sec:     $WALL"
  echo ""
  echo "Predictions:   $PREDS"
  [ "$BASELINE" = 1 ] && echo "Baseline preds: $BASE_PREDS"
  echo ""
  echo "Next: score with the official SWE-bench evaluator."
  echo "  pip install swebench"
  echo "  python -m swebench.harness.run_evaluation \\"
  case "$TASK_SET" in
    lite)     echo "    --dataset_name princeton-nlp/SWE-bench_Lite \\" ;;
    verified) echo "    --dataset_name princeton-nlp/SWE-bench_Verified \\" ;;
    full)     echo "    --dataset_name princeton-nlp/SWE-bench \\" ;;
  esac
  echo "    --predictions_path $PREDS \\"
  echo "    --max_workers 4 \\"
  echo "    --run_id openring-$TASK_SET-$(date +%Y%m%d-%H%M%S)"
} | tee "$SUMMARY"
