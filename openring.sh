#!/usr/bin/env bash
# openring.sh — Multi-agent orchestrator for local coding CLIs.
#
# Coordinates three roles (Architect / Adversary / Grinder) across whichever
# of `claude`, `gh copilot`, and `ollama` are installed. Shared state lives
# in CONSTITUTION.md (hard rules) and RING_GOALS.md (goals + known issues).
#
# Safety: this script runs agents that can edit files and make git commits.
# Run it on a scratch branch. Review diffs before merging.

set -uo pipefail

# ---------- Config ----------
MAX_CYCLES="${MAX_CYCLES:-15}"
CHAOS_RATE="${CHAOS_RATE:-20}"          # % chance a cycle is forced to Adversary
COOLDOWN="${COOLDOWN:-5}"               # seconds between cycles
STALL_LIMIT="${STALL_LIMIT:-3}"         # consecutive no-progress cycles before breaker
SUMMARIZE_EVERY="${SUMMARIZE_EVERY:-10}" # summarize RING_GOALS.md every N cycles
GOALS_SOFT_CAP="${GOALS_SOFT_CAP:-800}"  # lines; trigger summarizer if exceeded
OLLAMA_MODEL="${OLLAMA_MODEL:-deepseek-coder-v2}"
LOG_DIR="${LOG_DIR:-.openring/logs}"

mkdir -p "$LOG_DIR"

# ---------- Preconditions ----------
if [ ! -f CONSTITUTION.md ] || [ ! -f RING_GOALS.md ]; then
  echo "❌ CONSTITUTION.md and RING_GOALS.md must exist in the current directory."
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "❌ Not inside a git repository. Run 'git init' first."
  exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }

HAVE_CLAUDE=0; have claude && HAVE_CLAUDE=1
HAVE_COPILOT=0; have gh && gh copilot --help >/dev/null 2>&1 && HAVE_COPILOT=1
HAVE_OLLAMA=0; have ollama && HAVE_OLLAMA=1

if [ $((HAVE_CLAUDE + HAVE_COPILOT + HAVE_OLLAMA)) -eq 0 ]; then
  echo "❌ None of claude / gh copilot / ollama are installed. Nothing to orchestrate."
  exit 1
fi

echo "🚀 OpenRing starting."
echo "   claude:     $([ $HAVE_CLAUDE -eq 1 ] && echo yes || echo no)"
echo "   gh copilot: $([ $HAVE_COPILOT -eq 1 ] && echo yes || echo no)"
echo "   ollama:     $([ $HAVE_OLLAMA -eq 1 ] && echo yes || echo no)"

# ---------- State ----------
CYCLE=0
STALL_COUNT=0
LAST_TREE_HASH="$(git write-tree 2>/dev/null || echo none)"

prompt_preamble() {
  cat <<'EOF'
You are one role in a multi-agent coding loop called OpenRing.
Ground rules:
- Read CONSTITUTION.md. Do not violate it. If a goal conflicts with the constitution, log the conflict in RING_GOALS.md under "Known Issues" and stop.
- Read RING_GOALS.md. It is the shared blackboard. When you are done, append a short bullet under "Cycle Log" describing exactly what you changed.
- Make real file edits. Do not just describe changes.
- Commit your changes with a clear message prefixed by your role (e.g. "architect: ...", "adversary: ...", "grinder: ...").
- Keep output terse. Do not paste whole files back to the terminal.
EOF
}

role_prompt_architect() {
  prompt_preamble
  cat <<'EOF'

ROLE: ARCHITECT.
- Pick the next unchecked item in RING_GOALS.md and implement it.
- Prefer small, testable steps over sweeping rewrites.
- If the goal is ambiguous, refine it in RING_GOALS.md first, then implement.
EOF
}

role_prompt_adversary() {
  prompt_preamble
  cat <<'EOF'

ROLE: ADVERSARY.
- Inspect the last 3 commits and the current tree.
- You MUST identify at least one concrete, reproducible flaw (bug, missing edge case, constitution violation, unhandled error, performance cliff, or missing test).
- If after honest effort you find none, append to Known Issues: "Adversary pass: no flaws found in <commit-sha>, verified by <check you actually ran>".
- Do NOT invent stylistic nits. Attack semantics, not aesthetics.
- Either fix the flaw yourself OR add a failing test that reproduces it, then commit.
EOF
}

role_prompt_grinder() {
  prompt_preamble
  cat <<'EOF'

ROLE: GRINDER.
- Run the project's build/test/lint. Fix whatever is red.
- No architectural changes. Smallest possible diffs.
- If you cannot make the build green in this cycle, log the remaining failure under Known Issues with the exact error and stop.
EOF
}

run_agent() {
  local role="$1" prompt="$2" log="$LOG_DIR/cycle-${CYCLE}-${role}.log"

  case "$role" in
    architect)
      [ $HAVE_CLAUDE -eq 1 ] || { echo "   (claude not installed; skipping)"; return 2; }
      claude -p "$prompt" 2>&1 | tee "$log"
      ;;
    adversary)
      # Adversary preferentially uses copilot (different model family = genuine second opinion).
      if [ $HAVE_COPILOT -eq 1 ]; then
        gh copilot suggest -t shell "$prompt" 2>&1 | tee "$log"
      elif [ $HAVE_CLAUDE -eq 1 ]; then
        claude -p "$prompt" 2>&1 | tee "$log"
      else
        echo "   (no adversary-capable CLI; skipping)"; return 2
      fi
      ;;
    grinder)
      if [ $HAVE_OLLAMA -eq 1 ]; then
        ollama run "$OLLAMA_MODEL" "$prompt" 2>&1 | tee "$log"
      elif [ $HAVE_CLAUDE -eq 1 ]; then
        claude -p "$prompt" 2>&1 | tee "$log"
      else
        echo "   (no grinder-capable CLI; skipping)"; return 2
      fi
      ;;
  esac
}

summarize_goals() {
  # Best-effort compression: keep structural sections, fold cycle log into a
  # single summary line, drop resolved Known Issues. Prefer claude; fall back
  # to a deterministic bash trim so the loop never blocks on model access.
  local log="$LOG_DIR/summarize-${CYCLE}.log"
  if [ $HAVE_CLAUDE -eq 1 ]; then
    claude -p "Compress RING_GOALS.md in place. Keep: Current Objective, Checkboxes (unchanged), unresolved Known Issues. Replace the Cycle Log with a single 'Summary through cycle $CYCLE' paragraph of at most 10 bullets. Resolved issues go into an 'Archive' section, one line each. Do not change the checkbox list. Commit with message 'summarize: compress RING_GOALS.md through cycle $CYCLE'." 2>&1 | tee "$log"
  else
    # Deterministic fallback: truncate cycle log to last 50 bullets.
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
    echo "- Forcing resolution: next Architect cycle must either (a) pick a smaller sub-task, (b) mark the current objective BLOCKED with a concrete reason, or (c) rewrite the objective."
    echo "- Adversary is suspended for 1 cycle to let Architect move."
  } >> RING_GOALS.md
  git add RING_GOALS.md
  git commit -m "breaker: log stall at cycle $CYCLE" >/dev/null 2>&1 || true
  STALL_COUNT=0
  CIRCUIT_BREAKER_SUSPEND_ADVERSARY=1
}

CIRCUIT_BREAKER_SUSPEND_ADVERSARY=0

# ---------- Main loop ----------
while (( CYCLE < MAX_CYCLES )); do
  CYCLE=$((CYCLE + 1))
  echo "========================================"
  echo "🌀 Cycle $CYCLE / $MAX_CYCLES"
  echo "========================================"

  # Role selection.
  ROLL=$((RANDOM % 100))
  if [ "$CIRCUIT_BREAKER_SUSPEND_ADVERSARY" -eq 1 ]; then
    CIRCUIT_BREAKER_SUSPEND_ADVERSARY=0
    ROLE="architect"
    echo "🔧 Post-breaker cycle: forcing Architect."
  elif [ "$ROLL" -lt "$CHAOS_RATE" ]; then
    ROLE="adversary"
    echo "🚨 Chaos round: Adversary."
  else
    case $((CYCLE % 3)) in
      1) ROLE="architect" ;;
      2) ROLE="adversary" ;;
      0) ROLE="grinder"   ;;
    esac
  fi

  case "$ROLE" in
    architect) PROMPT="$(role_prompt_architect)" ;;
    adversary) PROMPT="$(role_prompt_adversary)" ;;
    grinder)   PROMPT="$(role_prompt_grinder)"   ;;
  esac

  echo "🎭 Role: $ROLE"
  run_agent "$ROLE" "$PROMPT" || echo "   (agent exited non-zero; continuing)"

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
