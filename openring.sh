#!/usr/bin/env bash
# openring.sh — the clock and the referee.
#
# opencode is the agent. This script only does what opencode can't do on its
# own: schedule unattended cycles, force role rotation on a timer, detect
# tree-level stalls, and hot-swap to a local Ollama model when a plan provider
# rate-limits or errors.
#
# Requirements: opencode installed and authenticated (opencode auth login),
# AGENTS.md present in cwd, and the .opencode/ preset copied in.

set -uo pipefail

# ---------- Config ----------
ARCHITECT_MODEL="${ARCHITECT_MODEL:-anthropic/claude-sonnet-4-5}"
ADVERSARY_MODEL="${ADVERSARY_MODEL:-github-copilot/gpt-5}"
GRINDER_MODEL="${GRINDER_MODEL:-google/gemini-2.5-pro}"
OLLAMA_MODEL="${OLLAMA_MODEL:-}"             # e.g. ollama/qwen2.5-coder
OLLAMA_IN_ROTATION="${OLLAMA_IN_ROTATION:-0}"

MAX_CYCLES="${MAX_CYCLES:-15}"
CHAOS_RATE="${CHAOS_RATE:-20}"
STALL_LIMIT="${STALL_LIMIT:-3}"
COOLDOWN="${COOLDOWN:-5}"
LOG_DIR="${LOG_DIR:-.openring/logs}"

# ---------- Preconditions ----------
command -v opencode >/dev/null 2>&1 || {
  echo "❌ opencode not found. Install: https://opencode.ai"; exit 1
}
[ -f AGENTS.md ] || {
  echo "❌ AGENTS.md not found in $(pwd). Copy the template from the OpenRing repo."; exit 1
}
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "❌ Not a git repo. Run 'git init' first."; exit 1
}

mkdir -p "$LOG_DIR"

echo "🚀 OpenRing starting in $(pwd)"
echo "   Architect: $ARCHITECT_MODEL"
echo "   Adversary: $ADVERSARY_MODEL"
echo "   Grinder:   $GRINDER_MODEL"
[ -n "$OLLAMA_MODEL" ] && echo "   Ollama:    $OLLAMA_MODEL $([ "$OLLAMA_IN_ROTATION" = 1 ] && echo '(in rotation)' || echo '(hot-swap fallback)')"

# ---------- Run opencode with a role prompt, with Ollama hot-swap on failure ----------
run_agent() {
  local role="$1" model="$2" log="$LOG_DIR/cycle-${CYCLE}-${role}.log"
  local prompt="@${role} Proceed per AGENTS.md. Read CONSTITUTION and Goals sections. Edit files, run checks, commit with a '${role}:' prefix. Append one bullet to the Cycle Log with what you did."

  opencode run --model "$model" "$prompt" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}

  if [ "$rc" -ne 0 ] && [ -n "$OLLAMA_MODEL" ] && [ "$model" != "$OLLAMA_MODEL" ]; then
    echo "   ⚠  $model failed (exit $rc). Hot-swapping to $OLLAMA_MODEL"
    opencode run --model "$OLLAMA_MODEL" "$prompt" 2>&1 | tee "$log.fallback"
  fi
}

# ---------- Main loop ----------
CYCLE=0
STALL_COUNT=0
LAST_TREE="$(git write-tree 2>/dev/null || echo none)"
SUSPEND_ADVERSARY_NEXT=0

while (( CYCLE < MAX_CYCLES )); do
  CYCLE=$((CYCLE + 1))
  echo "════════ Cycle $CYCLE / $MAX_CYCLES ════════"

  # Role selection.
  if [ "$SUSPEND_ADVERSARY_NEXT" = 1 ]; then
    SUSPEND_ADVERSARY_NEXT=0
    ROLE="architect"
    MODEL="$ARCHITECT_MODEL"
    echo "🔧 Post-breaker: forcing Architect."
  elif (( RANDOM % 100 < CHAOS_RATE )); then
    ROLE="adversary"
    MODEL="$ADVERSARY_MODEL"
    echo "🚨 Chaos round: Adversary."
  elif [ "$OLLAMA_IN_ROTATION" = 1 ] && [ -n "$OLLAMA_MODEL" ]; then
    case $((CYCLE % 4)) in
      1) ROLE="architect"; MODEL="$ARCHITECT_MODEL" ;;
      2) ROLE="adversary"; MODEL="$ADVERSARY_MODEL" ;;
      3) ROLE="grinder";   MODEL="$GRINDER_MODEL"   ;;
      0) ROLE="grinder";   MODEL="$OLLAMA_MODEL"    ;;
    esac
  else
    case $((CYCLE % 3)) in
      1) ROLE="architect"; MODEL="$ARCHITECT_MODEL" ;;
      2) ROLE="adversary"; MODEL="$ADVERSARY_MODEL" ;;
      0) ROLE="grinder";   MODEL="$GRINDER_MODEL"   ;;
    esac
  fi

  echo "🎭 $ROLE  ·  $MODEL"
  run_agent "$ROLE" "$MODEL" || echo "   (non-zero exit; continuing)"

  # Stall check.
  NEW_TREE="$(git write-tree 2>/dev/null || echo none)"
  if [ "$NEW_TREE" = "$LAST_TREE" ]; then
    STALL_COUNT=$((STALL_COUNT + 1))
    echo "⏸  No tree change (stall $STALL_COUNT / $STALL_LIMIT)"
    if [ "$STALL_COUNT" -ge "$STALL_LIMIT" ]; then
      echo "🧯 Circuit breaker tripped."
      {
        echo ""
        echo "## Circuit Breaker — cycle $CYCLE"
        echo "- No tree changes for $STALL_COUNT consecutive cycles."
        echo "- Next Architect turn must: (a) pick a smaller sub-task, (b) mark the current objective BLOCKED with a concrete reason, or (c) rewrite it."
      } >> AGENTS.md
      git add AGENTS.md
      git commit -m "breaker: log stall at cycle $CYCLE" >/dev/null 2>&1 || true
      STALL_COUNT=0
      SUSPEND_ADVERSARY_NEXT=1
    fi
  else
    STALL_COUNT=0
    LAST_TREE="$NEW_TREE"
  fi

  echo "💤 ${COOLDOWN}s cooldown"
  sleep "$COOLDOWN"
done

echo "🛑 Reached MAX_CYCLES=$MAX_CYCLES. Done."
