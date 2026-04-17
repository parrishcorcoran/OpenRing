#!/usr/bin/env bash
# openring.sh — the clock and the referee.
#
# Three peer models take turns in a simple round-robin. On each turn, the
# current model either PRODUCES (makes forward progress on GOAL.md) or, with
# probability CHAOS_RATE, ANALYZES the previous turn's commit for flaws.
#
# opencode is the agent — it edits files, runs bash, commits to git.
# OpenRing only does what opencode can't: schedule the rotation, pick the
# mode per turn, detect stalls, check the goal-reached signal, and hot-swap
# to Ollama when a plan model errors.
#
# Optional: pair with the Vercel dashboard for remote status + whiteboard
# by setting OPENRING_DASHBOARD_URL + OPENRING_DASHBOARD_TOKEN.
#
# Requirements: opencode installed and authenticated (opencode auth login);
# AGENTS.md, GOAL.md, and .opencode/ preset present in cwd; inside a git repo.

set -uo pipefail

# ---------- Config ----------
# Three peer models. Different families strongly recommended — same-family
# critique rubber-stamps. Run `opencode models` to see what you have access to.
MODEL_1="${MODEL_1:-anthropic/claude-sonnet-4-5}"
MODEL_2="${MODEL_2:-github-copilot/gpt-5}"
MODEL_3="${MODEL_3:-google/gemini-2.5-pro}"

# Optional: local fallback and/or 4th rotation slot.
OLLAMA_MODEL="${OLLAMA_MODEL:-}"                # e.g. ollama/qwen2.5-coder
OLLAMA_IN_ROTATION="${OLLAMA_IN_ROTATION:-0}"   # 1 = Ollama is a 4th peer

# Loop behavior.
MAX_CYCLES="${MAX_CYCLES:-15}"
CHAOS_RATE="${CHAOS_RATE:-33}"                  # % chance the current turn is Critic instead of Builder
STALL_LIMIT="${STALL_LIMIT:-2}"                 # consecutive no-tree-change turns → circuit breaker
COOLDOWN="${COOLDOWN:-5}"                       # seconds between turns
LOG_DIR="${LOG_DIR:-.openring/logs}"

# Remote dashboard (optional).
DASH_URL="${OPENRING_DASHBOARD_URL:-}"
DASH_TOKEN="${OPENRING_DASHBOARD_TOKEN:-}"
REMOTE_BRANCH="${OPENRING_REMOTE_BRANCH:-}"     # e.g. "origin main" to git pull/push each turn

WHITEBOARD_FILE="WHITEBOARD.md"
GOAL_FILE="GOAL.md"

# ---------- Preconditions ----------
command -v opencode >/dev/null 2>&1 || { echo "❌ opencode not found. Install: https://opencode.ai"; exit 1; }
[ -f AGENTS.md ]      || { echo "❌ AGENTS.md not found. Copy the template from the OpenRing repo."; exit 1; }
[ -f "$GOAL_FILE" ]   || { echo "❌ $GOAL_FILE not found. Copy the template from the OpenRing repo."; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "❌ Not a git repo. Run 'git init' first."; exit 1; }

mkdir -p "$LOG_DIR"
HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1

# Build the rotation pool from configured models.
MODELS=()
[ -n "$MODEL_1" ] && MODELS+=("$MODEL_1")
[ -n "$MODEL_2" ] && MODELS+=("$MODEL_2")
[ -n "$MODEL_3" ] && MODELS+=("$MODEL_3")
[ "$OLLAMA_IN_ROTATION" = "1" ] && [ -n "$OLLAMA_MODEL" ] && MODELS+=("$OLLAMA_MODEL")
[ "${#MODELS[@]}" -ge 1 ] || { echo "❌ Need at least one MODEL_{1,2,3} configured."; exit 1; }
[ "${#MODELS[@]}" -eq 1 ] && echo "⚠️  Only one model configured — this is not multi-agent. Research says a single strong model usually matches this at equal compute."

echo "🚀 OpenRing starting in $(pwd)"
for i in "${!MODELS[@]}"; do
  echo "   model $((i + 1)): ${MODELS[$i]}"
done
[ -n "$OLLAMA_MODEL" ] && [ "$OLLAMA_IN_ROTATION" != "1" ] && echo "   ollama hot-swap fallback: $OLLAMA_MODEL"
[ -n "$DASH_URL" ] && echo "   dashboard: $DASH_URL"
[ -n "$REMOTE_BRANCH" ] && echo "   remote: pull/push $REMOTE_BRANCH each turn"
echo "   chaos rate: $CHAOS_RATE%  ·  stall limit: $STALL_LIMIT  ·  max cycles: $MAX_CYCLES"

# Cross-family warning: if any two models share a provider prefix, same-family critique may rubber-stamp.
declare -A SEEN_PROVIDERS
for m in "${MODELS[@]}"; do
  p="${m%%/*}"
  if [ -n "${SEEN_PROVIDERS[$p]:-}" ]; then
    echo ""
    echo "⚠️  Two or more rotation models share provider '$p'."
    echo "   Same-family critique tends to rubber-stamp. Mix providers for real critique"
    echo "   (anthropic/* + github-copilot/* + google/*, or add ollama/* for a free third)."
    echo ""
    break
  fi
  SEEN_PROVIDERS[$p]=1
done

# ---------- Dashboard helpers ----------
dash() {
  [ -z "$DASH_URL" ] || [ -z "$DASH_TOKEN" ] || [ "$HAVE_CURL" = 0 ] && return 0
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sfS -m 5 -X "$method" "$DASH_URL$path" \
      -H "authorization: Bearer $DASH_TOKEN" \
      -H "content-type: application/json" \
      -d "$body" 2>/dev/null || true
  else
    curl -sfS -m 5 -X "$method" "$DASH_URL$path" \
      -H "authorization: Bearer $DASH_TOKEN" 2>/dev/null || true
  fi
}

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'; }

report_status() {
  [ -z "$DASH_URL" ] && return 0
  local sha; sha="$(git rev-parse --short HEAD 2>/dev/null || echo "")"
  local tree_clean="true"; [ -n "$(git status --porcelain)" ] && tree_clean="false"
  dash POST /api/ingest "{\"cycle\":$CYCLE,\"role\":\"${MODE}(${MODEL})\",\"model\":\"$MODEL\",\"last_commit_sha\":\"$sha\",\"stall_count\":$STALL_COUNT,\"tree_clean\":$tree_clean}" >/dev/null
}

report_tail() {
  [ -z "$DASH_URL" ] && return 0
  local log="$1"; [ -f "$log" ] || return 0
  local lines_json
  lines_json=$(tail -n 80 "$log" | awk 'BEGIN{first=1}{
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t");
    if (first) {first=0} else {printf ","}
    printf "\"%s\"", $0
  }')
  dash POST /api/tail "{\"cycle\":$CYCLE,\"role\":\"${MODE}(${MODEL})\",\"lines\":[$lines_json]}" >/dev/null
}

poll_control() { [ -z "$DASH_URL" ] && echo "" && return 0; dash GET /api/control; }
clear_control() { [ -z "$DASH_URL" ] && return 0; dash POST /api/control '{"command":null}' >/dev/null; }

sync_whiteboard_in() {
  [ -z "$DASH_URL" ] && return 0
  local remote; remote=$(dash GET /api/whiteboard)
  [ -z "$remote" ] && return 0
  local content updated_at
  if command -v jq >/dev/null 2>&1; then
    content=$(printf '%s' "$remote" | jq -r '.content // ""')
    updated_at=$(printf '%s' "$remote" | jq -r '.updated_at // 0')
  elif command -v python3 >/dev/null 2>&1; then
    content=$(printf '%s' "$remote" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("content",""),end="")')
    updated_at=$(printf '%s' "$remote" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("updated_at",0))')
  else
    return 0
  fi
  local file_mtime=0
  [ -f "$WHITEBOARD_FILE" ] && file_mtime=$(stat -c %Y "$WHITEBOARD_FILE" 2>/dev/null || stat -f %m "$WHITEBOARD_FILE" 2>/dev/null || echo 0)
  local updated_sec=$((updated_at / 1000))
  if [ "$updated_sec" -gt "$file_mtime" ] && [ -n "$content" ]; then
    printf '%s' "$content" > "$WHITEBOARD_FILE"
    git add "$WHITEBOARD_FILE"
    git commit -m "whiteboard: sync from dashboard" >/dev/null 2>&1 || true
    echo "📥 Whiteboard pulled from dashboard."
  fi
}

sync_whiteboard_out() {
  [ -z "$DASH_URL" ] && return 0
  [ -f "$WHITEBOARD_FILE" ] || return 0
  local content; content=$(cat "$WHITEBOARD_FILE")
  local escaped; escaped=$(printf '%s' "$content" | json_str)
  dash POST /api/whiteboard "{\"content\":$escaped,\"source\":\"loop\"}" >/dev/null
}

whiteboard_hard_stop() {
  [ -f "$WHITEBOARD_FILE" ] || return 0
  local below; below=$(awk '/Your instruction goes below this line/{found=1;next} found' "$WHITEBOARD_FILE" 2>/dev/null)
  [ -z "$below" ] && below=$(cat "$WHITEBOARD_FILE")
  if echo "$below" | grep -qE '^\s*STOP\s*$'; then echo "STOP"; return 0; fi
  if echo "$below" | grep -qE '^\s*PAUSE\s*$'; then echo "PAUSE"; return 0; fi
  if echo "$below" | grep -qE '^\s*FORCE ADVERSARY\s*$'; then echo "FORCE-CRITIC"; return 0; fi
  if echo "$below" | grep -qE '^\s*FORCE CRITIC\s*$'; then echo "FORCE-CRITIC"; return 0; fi
}

goal_reached() {
  # Loop stops when GOAL.md has no unchecked boxes OR contains "GOAL: COMPLETE".
  [ -f "$GOAL_FILE" ] || return 1
  grep -qE '^\s*GOAL:\s*COMPLETE\s*$' "$GOAL_FILE" && return 0
  grep -qE '^\s*-\s*\[\s*\]' "$GOAL_FILE" && return 1
  return 0
}

# ---------- opencode runner ----------
run_turn() {
  local mode="$1" model="$2" log="$LOG_DIR/cycle-${CYCLE}-${mode}.log"
  local agent prompt
  if [ "$mode" = "analyze" ]; then
    agent="critic"
    prompt="@critic Analyze the previous turn's commit per .opencode/agent/critic.md. Read AGENTS.md and GOAL.md. Do not produce forward work this turn."
  else
    agent="builder"
    prompt="@builder Proceed per .opencode/agent/builder.md. Read AGENTS.md and GOAL.md. Check WHITEBOARD.md first — instructions there supersede the current goal. Commit when done."
  fi

  opencode run --model "$model" "$prompt" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}

  if [ "$rc" -ne 0 ] && [ -n "$OLLAMA_MODEL" ] && [ "$model" != "$OLLAMA_MODEL" ]; then
    echo "   ⚠  $model failed (exit $rc). Hot-swapping to $OLLAMA_MODEL"
    opencode run --model "$OLLAMA_MODEL" "$prompt" 2>&1 | tee "$log.fallback"
  fi
  report_tail "$log"
}

# ---------- Main loop ----------
CYCLE=0
STALL_COUNT=0
LAST_TREE="$(git write-tree 2>/dev/null || echo none)"
FORCE_CRITIC_NEXT=0
SUSPEND_CRITIC_NEXT=0
PAUSED=0

while (( CYCLE < MAX_CYCLES )); do
  # Check goal-reached signal before starting a new turn.
  if goal_reached; then
    echo "🎯 Goal reached. Ring paused, awaiting human."
    echo "   Edit GOAL.md (add new checkboxes or remove 'GOAL: COMPLETE') and re-run ./openring.sh."
    exit 0
  fi

  CYCLE=$((CYCLE + 1))
  echo "════════ Cycle $CYCLE / $MAX_CYCLES ════════"

  # Pull from remote if configured (picks up GitHub-edited whiteboard or goal).
  if [ -n "$REMOTE_BRANCH" ]; then
    # shellcheck disable=SC2086
    git pull --ff-only $REMOTE_BRANCH >/dev/null 2>&1 || echo "   (git pull failed; continuing)"
  fi

  sync_whiteboard_in

  # Hard-stop phrases in whiteboard.
  HS="$(whiteboard_hard_stop)"
  case "$HS" in
    STOP)         echo "🛑 Whiteboard STOP. Exiting."; break ;;
    PAUSE)        echo "⏸  Whiteboard PAUSE. Sleeping ${COOLDOWN}s."; sleep "$COOLDOWN"; CYCLE=$((CYCLE - 1)); continue ;;
    FORCE-CRITIC) FORCE_CRITIC_NEXT=1 ;;
  esac

  # Remote control commands.
  CTRL=$(poll_control)
  CTRL_CMD=""
  if [ -n "$CTRL" ] && command -v python3 >/dev/null 2>&1; then
    CTRL_CMD=$(printf '%s' "$CTRL" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("command") or "")' 2>/dev/null)
  fi
  case "$CTRL_CMD" in
    stop)            echo "🛑 Control STOP. Exiting."; clear_control; break ;;
    pause)           echo "⏸  Control PAUSE."; PAUSED=1 ;;
    resume)          echo "▶  Control RESUME."; PAUSED=0; clear_control ;;
    skip)            echo "⏭  Control SKIP."; clear_control; CYCLE=$((CYCLE - 1)); sleep "$COOLDOWN"; continue ;;
    force-adversary) FORCE_CRITIC_NEXT=1; clear_control ;;
  esac
  if [ "$PAUSED" = 1 ]; then sleep "$COOLDOWN"; CYCLE=$((CYCLE - 1)); continue; fi

  # Pick the model for this turn (round-robin).
  MODEL_IDX=$(( (CYCLE - 1) % ${#MODELS[@]} ))
  MODEL="${MODELS[$MODEL_IDX]}"

  # Pick the mode for this turn.
  if [ "$SUSPEND_CRITIC_NEXT" = 1 ]; then
    SUSPEND_CRITIC_NEXT=0
    MODE="produce"
    echo "🔧 Post-breaker: forcing Builder to move."
  elif [ "$FORCE_CRITIC_NEXT" = 1 ]; then
    FORCE_CRITIC_NEXT=0
    MODE="analyze"
    echo "🚨 Forced Critic (whiteboard / control)."
  elif (( RANDOM % 100 < CHAOS_RATE )); then
    MODE="analyze"
    echo "🚨 Chaos: this turn is Critic."
  else
    MODE="produce"
  fi

  echo "🎭 turn $CYCLE  ·  model=$MODEL  ·  mode=$MODE"
  report_status
  run_turn "$MODE" "$MODEL" || echo "   (non-zero exit; continuing)"

  # Whiteboard may have been wiped by a Builder that addressed it — sync out.
  [ "$MODE" = "produce" ] && sync_whiteboard_out

  NEW_TREE="$(git write-tree 2>/dev/null || echo none)"

  # Soft check: Critic turns that produced commits should usually touch a test/spec.
  if [ "$MODE" = "analyze" ] && [ "$NEW_TREE" != "$LAST_TREE" ]; then
    if ! git diff --name-only HEAD~1 HEAD 2>/dev/null | grep -qiE '(test|spec)'; then
      echo "   ℹ  Critic committed but did not touch a test/spec file. Review whether critique was evidence-based."
    fi
  fi

  # Push commits back to remote if configured.
  if [ -n "$REMOTE_BRANCH" ]; then
    # shellcheck disable=SC2086
    git push $REMOTE_BRANCH >/dev/null 2>&1 || echo "   (git push failed; continuing)"
  fi

  # Stall detection.
  if [ "$NEW_TREE" = "$LAST_TREE" ]; then
    STALL_COUNT=$((STALL_COUNT + 1))
    echo "⏸  No tree change (stall $STALL_COUNT / $STALL_LIMIT)"
    if [ "$STALL_COUNT" -ge "$STALL_LIMIT" ]; then
      echo "🧯 Circuit breaker tripped."
      {
        echo ""
        echo "## Circuit Breaker — cycle $CYCLE"
        echo "- No tree changes for $STALL_COUNT consecutive turns."
        echo "- Next Builder turn must: (a) shrink the current checkbox, (b) mark it BLOCKED with a concrete reason, or (c) rewrite it."
      } >> AGENTS.md
      git add AGENTS.md
      git commit -m "breaker: log stall at cycle $CYCLE" >/dev/null 2>&1 || true
      STALL_COUNT=0
      SUSPEND_CRITIC_NEXT=1
    fi
  else
    STALL_COUNT=0
    LAST_TREE="$NEW_TREE"
  fi

  echo "💤 ${COOLDOWN}s cooldown"
  sleep "$COOLDOWN"
done

if goal_reached; then
  echo "🎯 Goal reached. Ring paused, awaiting human."
else
  echo "🛑 Reached MAX_CYCLES=$MAX_CYCLES or STOP. Done."
fi
