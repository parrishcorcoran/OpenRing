#!/usr/bin/env bash
# openring.sh — Multi-agent orchestrator over `opencode`.
#
# Rotates three cognitive roles (Architect / Adversary / Grinder), each backed
# by a different provider/model through the same `opencode` CLI. opencode is
# the agent — it handles file edits, bash, and git commits. OpenRing just
# handles rotation, adversarial framing, stall detection, and state.
#
# Prereqs:
#   - opencode installed and on PATH (https://opencode.ai)
#   - `opencode auth login` run once per provider you want to use
#     (Anthropic, GitHub Copilot, Google Gemini are the defaults below)
#   - CONSTITUTION.md and RING_GOALS.md in the current directory
#   - Running inside a git repo (a scratch branch, please)

set -uo pipefail

# ---------- Config ----------
MAX_CYCLES="${MAX_CYCLES:-15}"
CHAOS_RATE="${CHAOS_RATE:-20}"            # % chance a cycle is forced to Adversary
COOLDOWN="${COOLDOWN:-5}"                 # seconds between cycles
STALL_LIMIT="${STALL_LIMIT:-3}"           # consecutive no-progress cycles → breaker
SUMMARIZE_EVERY="${SUMMARIZE_EVERY:-10}"  # summarize RING_GOALS.md every N cycles
GOALS_SOFT_CAP="${GOALS_SOFT_CAP:-800}"   # lines; trigger summarizer if exceeded
LOG_DIR="${LOG_DIR:-.openring/logs}"

# Per-role models. Override any of these to taste. Leave a model empty to
# force-disable that role. Provider/model identifiers follow opencode's
# "<provider>/<model>" convention — confirm current IDs with `opencode models`
# since vendors ship new versions regularly. All three default providers can be
# logged in via plan subscription (no API keys) using `opencode auth login`.
ARCHITECT_MODEL="${ARCHITECT_MODEL:-anthropic/claude-sonnet-4-5}"
ADVERSARY_MODEL="${ADVERSARY_MODEL:-github-copilot/gpt-5}"
GRINDER_MODEL="${GRINDER_MODEL:-google/gemini-2.5-pro}"

# Optional local model via Ollama. Used two ways:
#   1. Fallback when a plan model errors (rate limit, credits exhausted, auth hiccup).
#   2. Set OLLAMA_IN_ROTATION=1 to also include Ollama as a 4th role in the
#      round-robin, so it does mechanical work every 4th cycle for free.
# Example value: "ollama/qwen2.5-coder" or "ollama/deepseek-coder-v2".
OLLAMA_MODEL="${OLLAMA_MODEL:-}"
OLLAMA_IN_ROTATION="${OLLAMA_IN_ROTATION:-0}"

mkdir -p "$LOG_DIR"

# ---------- Preconditions ----------
if ! command -v opencode >/dev/null 2>&1; then
  echo "❌ opencode not found on PATH."
  echo "   Install: https://opencode.ai  (then run 'opencode auth login' per provider)"
  exit 1
fi

if [ ! -f CONSTITUTION.md ] || [ ! -f RING_GOALS.md ]; then
  echo "❌ CONSTITUTION.md and RING_GOALS.md must exist in the current directory."
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "❌ Not inside a git repository. Run 'git init' first."
  exit 1
fi

echo "🚀 OpenRing starting."
echo "   Architect: ${ARCHITECT_MODEL:-<disabled>}"
echo "   Adversary: ${ADVERSARY_MODEL:-<disabled>}"
echo "   Grinder:   ${GRINDER_MODEL:-<disabled>}"
echo "   Ollama:    ${OLLAMA_MODEL:-<not configured>} $([ "$OLLAMA_IN_ROTATION" = "1" ] && echo '(in rotation)' || echo '(fallback only)')"
echo "   Tip: if a provider errors with auth, run: opencode auth login"

# ---------- State ----------
CYCLE=0
STALL_COUNT=0
LAST_TREE_HASH="$(git write-tree 2>/dev/null || echo none)"
CIRCUIT_BREAKER_SUSPEND_ADVERSARY=0

prompt_preamble() {
  cat <<'EOF'
You are one role in a multi-agent coding loop called OpenRing.

Ground rules:
- Read CONSTITUTION.md first. Do not violate it. If a goal conflicts with the
  constitution, append the conflict to RING_GOALS.md under "Known Issues" and stop.
- Read RING_GOALS.md. It is the shared blackboard. When you are done, append a
  short bullet under "Cycle Log" describing what you changed (role + summary).
- Make real file edits. Do not just describe changes in prose.
- Commit your changes with git. Prefix the commit message with your role:
  "architect:", "adversary:", or "grinder:".
- Keep terminal output terse. Do not paste whole files back.
EOF
}

role_prompt_architect() {
  prompt_preamble
  cat <<'EOF'

ROLE: ARCHITECT.
- Pick the next unchecked item in RING_GOALS.md and implement it.
- Prefer small, testable steps over sweeping rewrites.
- If the goal is ambiguous, sharpen it in RING_GOALS.md first, then implement.
- If tests exist, run them and make sure they still pass before committing.
EOF
}

role_prompt_adversary() {
  prompt_preamble
  cat <<'EOF'

ROLE: ADVERSARY.
- Inspect the last 3 commits (git log -3, git diff HEAD~1) and the current tree.
- You MUST identify at least one concrete, reproducible flaw: bug, missing edge
  case, constitution violation, unhandled error, performance cliff, or missing
  test. Attack semantics, not aesthetics. No stylistic nits.
- If after honest effort you find nothing, append to Known Issues:
  "Adversary pass: no flaws found in <commit-sha>, verified by <checks you ran>".
- Either fix the flaw yourself OR add a failing test that reproduces it, then
  commit. A failing test is the preferred output.
EOF
}

role_prompt_grinder() {
  prompt_preamble
  cat <<'EOF'

ROLE: GRINDER.
- Run the project's build / tests / lint. Fix whatever is red.
- No architectural changes. Smallest possible diffs. One concern per commit.
- If you cannot make the build green in this cycle, log the remaining failure
  under Known Issues with the exact error and stop. Do not guess.
EOF
}

# run_opencode MODEL PROMPT LOG
# Runs opencode once. Returns opencode's real exit code (PIPESTATUS[0] past tee).
run_opencode() {
  local model="$1" prompt="$2" log="$3"
  opencode run --model "$model" "$prompt" 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

# run_agent ROLE MODEL PROMPT
# Tries the role's primary model, then hot-swaps to the Ollama fallback on
# failure (rate limit, credits exhausted, auth hiccup). Hot-swap is fast —
# a ~7B local model is in memory after one cycle and responds in seconds.
run_agent() {
  local role="$1" model="$2" prompt="$3"
  local log="$LOG_DIR/cycle-${CYCLE}-${role}.log"

  if [ -z "$model" ]; then
    if [ -n "$OLLAMA_MODEL" ]; then
      echo "   ($role has no primary model; using Ollama directly)"
      run_opencode "$OLLAMA_MODEL" "$prompt" "$log"
      return $?
    fi
    echo "   ($role has no model configured; skipping)"
    return 2
  fi

  if run_opencode "$model" "$prompt" "$log"; then
    return 0
  fi

  local rc=$?
  if [ -n "$OLLAMA_MODEL" ] && [ "$model" != "$OLLAMA_MODEL" ]; then
    echo "   ⚠  $model failed (exit $rc). Hot-swapping to Ollama: $OLLAMA_MODEL"
    run_opencode "$OLLAMA_MODEL" "$prompt" "$log.fallback"
    return $?
  fi
  return $rc
}

summarize_goals() {
  local log="$LOG_DIR/summarize-${CYCLE}.log"
  local summarizer_model="${SUMMARIZER_MODEL:-$ARCHITECT_MODEL}"
  if [ -n "$summarizer_model" ]; then
    opencode run --model "$summarizer_model" \
      "Compress RING_GOALS.md in place. Keep: Current Objective, Checkboxes (unchanged), unresolved Known Issues. Replace the Cycle Log with a single 'Summary through cycle $CYCLE' section of at most 10 bullets. Move resolved issues to an 'Archive' section, one line each. Do not modify the checkbox list. Commit with message 'summarize: compress RING_GOALS.md through cycle $CYCLE'." \
      2>&1 | tee "$log"
  else
    # Deterministic fallback: trim Cycle Log to last 50 entries.
    awk '
      /^## Cycle Log/ { inlog=1; print; print "_(older entries elided by summarizer)_"; next }
      /^## / && inlog { inlog=0 }
      inlog { buf[NR]=$0; next }
      { print }
      END {
        n=0; for (i in buf) n++
        start = (n > 50) ? n - 50 : 0
        c = 0
        for (i in buf) { if (c++ >= start) print buf[i] }
      }
    ' RING_GOALS.md > RING_GOALS.md.tmp && mv RING_GOALS.md.tmp RING_GOALS.md
    git add RING_GOALS.md && git commit -m "summarize: trim RING_GOALS.md cycle log (fallback)" >/dev/null 2>&1 || true
  fi
}

circuit_break() {
  echo "🧯 Circuit breaker tripped after $STALL_COUNT stalled cycles."
  {
    echo ""
    echo "## Circuit Breaker — cycle $CYCLE"
    echo "- No tree changes detected for $STALL_COUNT consecutive cycles."
    echo "- Next Architect cycle must either (a) pick a smaller sub-task,"
    echo "  (b) mark the current objective BLOCKED with a concrete reason,"
    echo "  or (c) rewrite the objective."
    echo "- Adversary suspended for 1 cycle to let Architect move."
  } >> RING_GOALS.md
  git add RING_GOALS.md
  git commit -m "breaker: log stall at cycle $CYCLE" >/dev/null 2>&1 || true
  STALL_COUNT=0
  CIRCUIT_BREAKER_SUSPEND_ADVERSARY=1
}

# ---------- Main loop ----------
while (( CYCLE < MAX_CYCLES )); do
  CYCLE=$((CYCLE + 1))
  echo "========================================"
  echo "🌀 Cycle $CYCLE / $MAX_CYCLES"
  echo "========================================"

  # Role selection.
  if [ "$CIRCUIT_BREAKER_SUSPEND_ADVERSARY" -eq 1 ]; then
    CIRCUIT_BREAKER_SUSPEND_ADVERSARY=0
    ROLE="architect"
    echo "🔧 Post-breaker cycle: forcing Architect."
  elif (( RANDOM % 100 < CHAOS_RATE )); then
    ROLE="adversary"
    echo "🚨 Chaos round: Adversary."
  elif [ "$OLLAMA_IN_ROTATION" = "1" ] && [ -n "$OLLAMA_MODEL" ]; then
    # 4-way rotation: every 4th cycle, Ollama does grinder-style cleanup for free.
    case $((CYCLE % 4)) in
      1) ROLE="architect"       ;;
      2) ROLE="adversary"       ;;
      3) ROLE="grinder"         ;;
      0) ROLE="local-grinder"   ;;
    esac
  else
    case $((CYCLE % 3)) in
      1) ROLE="architect" ;;
      2) ROLE="adversary" ;;
      0) ROLE="grinder"   ;;
    esac
  fi

  case "$ROLE" in
    architect)     PROMPT="$(role_prompt_architect)"; MODEL="$ARCHITECT_MODEL" ;;
    adversary)     PROMPT="$(role_prompt_adversary)"; MODEL="$ADVERSARY_MODEL" ;;
    grinder)       PROMPT="$(role_prompt_grinder)";   MODEL="$GRINDER_MODEL"   ;;
    local-grinder) PROMPT="$(role_prompt_grinder)";   MODEL="$OLLAMA_MODEL"    ;;
  esac

  echo "🎭 Role: $ROLE  ·  Model: ${MODEL:-<disabled>}"
  run_agent "$ROLE" "$MODEL" "$PROMPT" || echo "   (agent exited non-zero; continuing)"

  # Progress check.
  NEW_TREE_HASH="$(git write-tree 2>/dev/null || echo none)"
  if [ "$NEW_TREE_HASH" = "$LAST_TREE_HASH" ]; then
    STALL_COUNT=$((STALL_COUNT + 1))
    echo "⏸  No tree change this cycle (stall $STALL_COUNT / $STALL_LIMIT)."
    if [ "$STALL_COUNT" -ge "$STALL_LIMIT" ]; then
      circuit_break
    fi
  else
    STALL_COUNT=0
    LAST_TREE_HASH="$NEW_TREE_HASH"
  fi

  # Context compression.
  GOALS_LINES=$(wc -l < RING_GOALS.md | tr -d ' ')
  if (( CYCLE % SUMMARIZE_EVERY == 0 )) || (( GOALS_LINES > GOALS_SOFT_CAP )); then
    echo "🗜  Summarizing RING_GOALS.md (lines=$GOALS_LINES)."
    summarize_goals
  fi

  echo "💤 Cooling down ${COOLDOWN}s."
  sleep "$COOLDOWN"
done

echo "🛑 Reached MAX_CYCLES=$MAX_CYCLES. Ring stopped."
