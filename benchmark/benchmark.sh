#!/usr/bin/env bash
# benchmark.sh — compare OpenRing vs a single-agent opencode baseline on a task.
#
# This is NOT a rigorous scientific benchmark. It's a side-by-side "try it on your
# own code" harness. One run of anything LLM-based is noisy; for a real comparison
# run it several times and look at averages. For a real scientific benchmark, see
# SWE-bench. This tool is for "does the Ring actually do better on *my* problem?"
#
# Usage:
#   benchmark/benchmark.sh --demo                          # use the built-in broken-fixture demo
#   benchmark/benchmark.sh --repo <path> --task "<text>"   # use your own repo
#
# Optional flags:
#   --baseline-model  model for single-agent run  (default: $ARCHITECT_MODEL)
#   --cycles          MAX_CYCLES for Ring run      (default: 10)
#   --test-cmd        how to run tests             (default: auto-detect)

set -uo pipefail

# ---------- Args ----------
MODE=""
TARGET_REPO=""
TASK=""
BASELINE_MODEL="${ARCHITECT_MODEL:-anthropic/claude-sonnet-4-5}"
RING_CYCLES="10"
TEST_CMD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --demo)           MODE="demo"; shift ;;
    --repo)           MODE="repo"; TARGET_REPO="$2"; shift 2 ;;
    --task)           TASK="$2"; shift 2 ;;
    --baseline-model) BASELINE_MODEL="$2"; shift 2 ;;
    --cycles)         RING_CYCLES="$2"; shift 2 ;;
    --test-cmd)       TEST_CMD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v opencode >/dev/null 2>&1 || { echo "❌ opencode not found"; exit 1; }
command -v git      >/dev/null 2>&1 || { echo "❌ git not found"; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t openring-bench.XXXXXX)"
trap 'echo "bench workdir: $WORK"' EXIT
echo "🏁 bench workdir: $WORK"

# ---------- Demo fixture: a tiny buggy Python package with a failing test. ----------
make_demo() {
  local dir="$1"
  mkdir -p "$dir/src" "$dir/tests"
  cat > "$dir/src/bump_alloc.py" <<'PY'
class BumpAllocator:
    """Tiny single-block bump allocator. Intentionally buggy for the demo."""
    def __init__(self, block_size: int):
        self.block = bytearray(block_size)
        self.head = 0

    def alloc(self, n: int) -> int:
        # BUG 1: no alignment handling.
        # BUG 2: no bounds check against block end.
        offset = self.head
        self.head = self.head + n
        return offset

    def reset(self) -> None:
        self.head = 0
PY
  cat > "$dir/tests/test_bump_alloc.py" <<'PY'
from src.bump_alloc import BumpAllocator

def test_alloc_happy_path():
    a = BumpAllocator(64)
    p1 = a.alloc(8)
    p2 = a.alloc(8)
    assert p1 == 0
    assert p2 == 8

def test_alloc_rejects_overflow():
    # Expectation: alloc beyond block end returns -1 rather than silently OOB.
    a = BumpAllocator(16)
    a.alloc(8)
    a.alloc(8)
    assert a.alloc(1) == -1, "expected -1 on OOB alloc"

def test_alloc_alignment():
    # Expectation: alloc returns a pointer aligned to 8 bytes.
    a = BumpAllocator(64)
    a.alloc(1)
    p = a.alloc(8)
    assert p % 8 == 0, f"expected 8-byte alignment, got offset {p}"
PY
  cat > "$dir/AGENTS.md" <<'MD'
# AGENTS.md
## Constitution
- Make `pytest tests/` green.
- Do not delete or disable tests. If a test is genuinely wrong, document why in a commit and stop.
- Do not stub functions to return fake values.

## Current Objective
Fix `src/bump_alloc.py` so all three tests pass.

## Checkboxes
- [ ] alignment bug fixed
- [ ] OOB bounds check added
- [ ] all three tests green

## Cycle Log
- [cycle 0] bench: fixture initialized.

## Known Issues
_None yet._
MD
  cp "$REPO_ROOT/WHITEBOARD.md.template" "$dir/WHITEBOARD.md" 2>/dev/null || echo "# 🪧 Whiteboard" > "$dir/WHITEBOARD.md"
  cp -r "$REPO_ROOT/.opencode" "$dir/" 2>/dev/null || true
  ( cd "$dir" && git init -q && git add -A && git commit -q -m "bench: initial fixture" )
}

# ---------- Setup source ----------
SRC_DIR="$WORK/src"
case "$MODE" in
  demo)
    echo "📦 Building demo fixture in $SRC_DIR"
    make_demo "$SRC_DIR"
    [ -z "$TASK" ] && TASK="Make pytest tests/ pass. Fix the bugs in src/bump_alloc.py."
    [ -z "$TEST_CMD" ] && TEST_CMD="python3 -m pytest tests/ -q"
    ;;
  repo)
    [ -z "$TARGET_REPO" ] && { echo "❌ --repo requires a path"; exit 2; }
    [ -d "$TARGET_REPO/.git" ] || { echo "❌ $TARGET_REPO is not a git repo"; exit 2; }
    [ -z "$TASK" ] && { echo "❌ --task is required"; exit 2; }
    echo "📦 Copying $TARGET_REPO to $SRC_DIR"
    git clone -q "$TARGET_REPO" "$SRC_DIR"
    ;;
  *) echo "usage: $0 --demo | --repo <path> --task \"<text>\""; exit 2 ;;
esac

# ---------- Auto-detect test command if not given ----------
if [ -z "$TEST_CMD" ]; then
  if   [ -f "$SRC_DIR/package.json" ];       then TEST_CMD="npm test --silent"
  elif [ -f "$SRC_DIR/Cargo.toml" ];         then TEST_CMD="cargo test --quiet"
  elif [ -f "$SRC_DIR/go.mod" ];             then TEST_CMD="go test ./..."
  elif [ -f "$SRC_DIR/pyproject.toml" ] || [ -f "$SRC_DIR/setup.py" ] || ls "$SRC_DIR"/tests/ >/dev/null 2>&1; then
    TEST_CMD="python3 -m pytest -q"
  else
    echo "⚠️  no --test-cmd and couldn't auto-detect; using 'true' (no verification)"
    TEST_CMD="true"
  fi
fi
echo "🧪 test cmd: $TEST_CMD"

# ---------- Two worktrees from the same starting point ----------
BASELINE="$WORK/baseline"
RING="$WORK/ring"
cp -R "$SRC_DIR" "$BASELINE"
cp -R "$SRC_DIR" "$RING"
# Reset git identities for both worktrees so commits don't fail inside the bench.
git -C "$BASELINE" config user.email "bench@openring.local" >/dev/null
git -C "$BASELINE" config user.name  "OpenRing Bench"       >/dev/null
git -C "$RING"     config user.email "bench@openring.local" >/dev/null
git -C "$RING"     config user.name  "OpenRing Bench"       >/dev/null

BASE_COMMIT=$(git -C "$SRC_DIR" rev-parse HEAD)
echo "🔖 starting commit: ${BASE_COMMIT:0:10}"

# ---------- Run baseline ----------
echo ""
echo "════════ Baseline: single-agent opencode ($BASELINE_MODEL) ════════"
BASELINE_START=$(date +%s)
(
  cd "$BASELINE"
  opencode run --model "$BASELINE_MODEL" \
    "$TASK  Make changes directly, run tests, commit when tests pass with message 'baseline: <summary>'. Do not stub. Do not disable tests." \
    2>&1 | tee "$WORK/baseline.log"
) || echo "(baseline exited non-zero)"
BASELINE_END=$(date +%s)

# ---------- Run OpenRing ----------
echo ""
echo "════════ OpenRing ($RING_CYCLES cycles) ════════"
RING_START=$(date +%s)
(
  cd "$RING"
  MAX_CYCLES="$RING_CYCLES" COOLDOWN=1 "$REPO_ROOT/openring.sh" 2>&1 | tee "$WORK/ring.log"
) || echo "(ring exited non-zero)"
RING_END=$(date +%s)

# ---------- Score both ----------
score() {
  local dir="$1" name="$2"
  local tests_status="unknown" commits=0 wall=0 loc_changed=0
  pushd "$dir" >/dev/null
    if bash -c "$TEST_CMD" >/dev/null 2>&1; then tests_status="PASS"; else tests_status="FAIL"; fi
    commits=$(git rev-list --count "${BASE_COMMIT}..HEAD" 2>/dev/null || echo 0)
    loc_changed=$(git diff --shortstat "${BASE_COMMIT}" HEAD 2>/dev/null | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | awk '{s+=$1} END{print s+0}')
  popd >/dev/null
  wall="$3"
  printf "%-12s  tests=%-4s  commits=%-3s  loc=%-5s  wall=%ss\n" "$name" "$tests_status" "$commits" "$loc_changed" "$wall"
}

echo ""
echo "════════ Results ════════"
score "$BASELINE" "baseline" "$((BASELINE_END - BASELINE_START))"
score "$RING"     "ring"     "$((RING_END - RING_START))"

echo ""
echo "Logs:"
echo "  baseline: $WORK/baseline.log"
echo "  ring:     $WORK/ring.log"
echo ""
echo "Diff each against starting commit:"
echo "  git -C $BASELINE diff ${BASE_COMMIT:0:10}"
echo "  git -C $RING     diff ${BASE_COMMIT:0:10}"
echo ""
echo "⚠️  One run of anything LLM-based is noisy. Re-run at least 3-5 times before drawing conclusions."
