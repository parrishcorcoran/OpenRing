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
# Three peer agents. Each is invoked via a command template with {prompt}
# substituted with a properly shell-quoted prompt. Defaults call opencode
# with a specific model. Override to call native CLIs directly:
#
#   AGENT_CMD_1="claude -p --permission-mode acceptEdits {prompt}"
#   AGENT_CMD_2="codex exec {prompt}"
#   AGENT_CMD_3="gemini --yolo {prompt}"
#
# Each slot also has a display label (used in logs and dashboard) and
# optionally a "family" hint used for the cross-family collision warning.
MODEL_1="${MODEL_1:-anthropic/claude-sonnet-4-5}"
MODEL_2="${MODEL_2:-github-copilot/gpt-5}"
MODEL_3="${MODEL_3:-google/gemini-2.5-pro}"

AGENT_CMD_1="${AGENT_CMD_1:-opencode run --model $MODEL_1 {prompt}}"
AGENT_CMD_2="${AGENT_CMD_2:-opencode run --model $MODEL_2 {prompt}}"
AGENT_CMD_3="${AGENT_CMD_3:-opencode run --model $MODEL_3 {prompt}}"

AGENT_LABEL_1="${AGENT_LABEL_1:-$MODEL_1}"
AGENT_LABEL_2="${AGENT_LABEL_2:-$MODEL_2}"
AGENT_LABEL_3="${AGENT_LABEL_3:-$MODEL_3}"

AGENT_FAMILY_1="${AGENT_FAMILY_1:-${MODEL_1%%/*}}"
AGENT_FAMILY_2="${AGENT_FAMILY_2:-${MODEL_2%%/*}}"
AGENT_FAMILY_3="${AGENT_FAMILY_3:-${MODEL_3%%/*}}"

# Optional: local fallback. Used when any plan CLI errors. Same template shape.
OLLAMA_MODEL="${OLLAMA_MODEL:-}"
OLLAMA_CMD="${OLLAMA_CMD:-${OLLAMA_MODEL:+opencode run --model $OLLAMA_MODEL {prompt}}}"
OLLAMA_LABEL="${OLLAMA_LABEL:-${OLLAMA_MODEL:-}}"
OLLAMA_IN_ROTATION="${OLLAMA_IN_ROTATION:-0}"

# Loop behavior.
MAX_CYCLES="${MAX_CYCLES:-15}"
CHAOS_RATE="${CHAOS_RATE:-33}"                  # % chance the current turn is Critic instead of Builder
STALL_LIMIT="${STALL_LIMIT:-2}"                 # consecutive no-tree-change turns → circuit breaker
COOLDOWN="${COOLDOWN:-5}"                       # seconds between turns
LOG_DIR="${LOG_DIR:-.openring/logs}"

# Turn mode:
#   round-robin (default) — one agent per turn, rotating. 1× wall-clock, 1× hourly rate-limit.
#   parallel              — every turn runs all agents concurrently in worktrees; scheduler picks
#                           a winner by TEST_CMD pass + commit + minimal diff, fast-forwards main.
#                           ~1× wall-clock, ~3× hourly rate-limit, same total work per N cycles.
RING_MODE="${RING_MODE:-round-robin}"
# Optional test command used as the primary signal for scoring parallel-mode winners.
# If unset, scoring falls back to "did it commit + smallest diff".
TEST_CMD="${TEST_CMD:-}"

# Remote dashboard (optional).
DASH_URL="${OPENRING_DASHBOARD_URL:-}"
DASH_TOKEN="${OPENRING_DASHBOARD_TOKEN:-}"
REMOTE_BRANCH="${OPENRING_REMOTE_BRANCH:-}"     # e.g. "origin main" to git pull/push each turn

WHITEBOARD_FILE="WHITEBOARD.md"
GOAL_FILE="GOAL.md"

# ---------- Preconditions ----------
[ -f AGENTS.md ]      || { echo "❌ AGENTS.md not found. Copy the template from the OpenRing repo."; exit 1; }
[ -f "$GOAL_FILE" ]   || { echo "❌ $GOAL_FILE not found. Copy the template from the OpenRing repo."; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "❌ Not a git repo. Run 'git init' first."; exit 1; }

mkdir -p "$LOG_DIR"
HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1

# Build the rotation pool. Each slot has: label (human-readable), command
# template (with {prompt}), and family (for cross-family collision check).
AGENTS_LABELS=()
AGENTS_CMDS=()
AGENTS_FAMILIES=()
[ -n "$AGENT_CMD_1" ] && AGENTS_LABELS+=("$AGENT_LABEL_1") && AGENTS_CMDS+=("$AGENT_CMD_1") && AGENTS_FAMILIES+=("$AGENT_FAMILY_1")
[ -n "$AGENT_CMD_2" ] && AGENTS_LABELS+=("$AGENT_LABEL_2") && AGENTS_CMDS+=("$AGENT_CMD_2") && AGENTS_FAMILIES+=("$AGENT_FAMILY_2")
[ -n "$AGENT_CMD_3" ] && AGENTS_LABELS+=("$AGENT_LABEL_3") && AGENTS_CMDS+=("$AGENT_CMD_3") && AGENTS_FAMILIES+=("$AGENT_FAMILY_3")
if [ "$OLLAMA_IN_ROTATION" = "1" ] && [ -n "$OLLAMA_CMD" ]; then
  AGENTS_LABELS+=("$OLLAMA_LABEL")
  AGENTS_CMDS+=("$OLLAMA_CMD")
  AGENTS_FAMILIES+=("ollama")
fi

[ "${#AGENTS_CMDS[@]}" -ge 1 ] || { echo "❌ Need at least one AGENT_CMD_{1,2,3} configured."; exit 1; }
[ "${#AGENTS_CMDS[@]}" -eq 1 ] && echo "⚠️  Only one agent configured — this is not multi-agent. Research says a single strong model usually matches this at equal compute."

# Sanity-check the binary for each agent command (best-effort: check the first token is on PATH).
for i in "${!AGENTS_CMDS[@]}"; do
  bin="${AGENTS_CMDS[$i]%% *}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "⚠️  agent $((i + 1)) (${AGENTS_LABELS[$i]}): '$bin' not found on PATH."
  fi
done

echo "🚀 OpenRing starting in $(pwd)"
for i in "${!AGENTS_LABELS[@]}"; do
  echo "   agent $((i + 1)): ${AGENTS_LABELS[$i]}  [${AGENTS_FAMILIES[$i]}]"
done
[ -n "$OLLAMA_CMD" ] && [ "$OLLAMA_IN_ROTATION" != "1" ] && echo "   ollama hot-swap fallback: ${OLLAMA_LABEL:-$OLLAMA_CMD}"
[ -n "$DASH_URL" ] && echo "   dashboard: $DASH_URL"
[ -n "$REMOTE_BRANCH" ] && echo "   remote: pull/push $REMOTE_BRANCH each turn"
echo "   ring mode: $RING_MODE  ·  chaos rate: $CHAOS_RATE%  ·  stall limit: $STALL_LIMIT  ·  max cycles: $MAX_CYCLES"
[ -n "$TEST_CMD" ] && echo "   test cmd (parallel scoring): $TEST_CMD"

# Cross-family warning: if any two rotation slots share a family, same-family critique may rubber-stamp.
declare -A SEEN_FAMILIES
for f in "${AGENTS_FAMILIES[@]}"; do
  [ -z "$f" ] && continue
  if [ -n "${SEEN_FAMILIES[$f]:-}" ]; then
    echo ""
    echo "⚠️  Two or more rotation slots share family '$f'."
    echo "   Same-family critique tends to rubber-stamp. Mix families for real critique"
    echo "   (anthropic + openai + google, or add ollama for a free fourth)."
    echo ""
    break
  fi
  SEEN_FAMILIES[$f]=1
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

# ---------- Agent runner ----------
# Substitute {prompt} in CMD_TEMPLATE with a shell-quoted prompt, then eval.
# eval is acceptable here because the template comes from user config, not
# untrusted input — same trust model as a shell alias or git config command.
run_template() {
  local cmd_template="$1" prompt="$2" log="$3"
  local quoted; quoted=$(printf '%q' "$prompt")
  local cmd="${cmd_template//\{prompt\}/$quoted}"
  eval "$cmd" 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

build_prompt() {
  local mode="$1"
  if [ "$mode" = "analyze" ]; then
    echo "@critic Analyze the previous turn's commit per .opencode/agent/critic.md (or equivalent built-in critic mode). Read AGENTS.md and GOAL.md. Find one concrete flaw with a reproducer, or log 'no flaws found, verified by X' with evidence. Do not produce forward work this turn."
  else
    echo "@builder Proceed per .opencode/agent/builder.md (or equivalent build mode). Read AGENTS.md and GOAL.md. Check WHITEBOARD.md first — instructions there supersede the current goal. Commit when done."
  fi
}

run_turn() {
  local mode="$1" cmd_template="$2" label="$3" log="$LOG_DIR/cycle-${CYCLE}-${mode}.log"
  local prompt; prompt=$(build_prompt "$mode")

  if run_template "$cmd_template" "$prompt" "$log"; then
    report_tail "$log"
    return 0
  fi
  local rc=$?

  if [ -n "$OLLAMA_CMD" ] && [ "$cmd_template" != "$OLLAMA_CMD" ]; then
    echo "   ⚠  $label failed (exit $rc). Hot-swapping to ${OLLAMA_LABEL:-Ollama}"
    run_template "$OLLAMA_CMD" "$prompt" "$log.fallback" || true
  fi
  report_tail "$log"
}

# Parallel mode: all agents run concurrently in their own worktrees. Winner is
# merged into the main working tree by fast-forward. Scoring:
#   + 200 if TEST_CMD passes (or +50 if unset)
#   + 50  if committed anything
#   - loc/10 (prefer minimal diffs, only when committed)
run_parallel_turn() {
  local mode; mode="$1"
  local prompt; prompt=$(build_prompt "$mode")
  local base_sha; base_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
  [ -z "$base_sha" ] && { echo "   (no HEAD yet; parallel mode needs at least one commit)"; return 1; }

  local wt_base=".openring/worktrees/cycle-$CYCLE"
  rm -rf "$wt_base"; mkdir -p "$wt_base"

  local -a BR WT
  local pids=()

  for i in "${!AGENTS_CMDS[@]}"; do
    BR[$i]="ring/c${CYCLE}-a${i}"
    WT[$i]="$wt_base/agent-$i"
    if ! git worktree add -b "${BR[$i]}" "${WT[$i]}" HEAD >/dev/null 2>&1; then
      echo "   ⚠  worktree create failed for agent $i; skipping"
      BR[$i]=""; WT[$i]=""
      continue
    fi
    local cmd_template="${AGENTS_CMDS[$i]}" label="${AGENTS_LABELS[$i]}"
    local log="$LOG_DIR/cycle-${CYCLE}-parallel-${i}-${mode}.log"
    (
      cd "${WT[$i]}" || exit 1
      quoted=$(printf '%q' "$prompt")
      full="${cmd_template//\{prompt\}/$quoted}"
      eval "$full" > "$log" 2>&1
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null; done

  # Score each worktree.
  local best_i=-1 best_score=-999999
  for i in "${!AGENTS_CMDS[@]}"; do
    [ -z "${WT[$i]:-}" ] && continue
    local wt="${WT[$i]}" br="${BR[$i]}"
    local commits; commits=$(git -C "$wt" rev-list --count "$base_sha..HEAD" 2>/dev/null || echo 0)
    local loc; loc=$(git -C "$wt" diff --shortstat "$base_sha" HEAD 2>/dev/null | grep -oE '[0-9]+ (insertion|deletion)' | awk '{s+=$1} END{print s+0}')
    local score=0
    if [ "$commits" -gt 0 ]; then
      score=$((score + 50))
      if [ -n "$TEST_CMD" ]; then
        if (cd "$wt" && bash -c "$TEST_CMD") >/dev/null 2>&1; then
          score=$((score + 200))
        fi
      fi
      score=$((score - loc / 10))
    fi
    echo "   agent $((i + 1)) (${AGENTS_LABELS[$i]}): commits=$commits loc=$loc score=$score"
    if [ "$score" -gt "$best_score" ]; then
      best_score=$score; best_i=$i
    fi
  done

  # Merge winner (fast-forward; all branches were forked from same base_sha).
  if [ "$best_i" -ge 0 ] && [ "$best_score" -gt 0 ]; then
    local winner_br="${BR[$best_i]}"
    echo "   🏆 winner: agent $((best_i + 1)) (${AGENTS_LABELS[$best_i]}) score=$best_score"
    git merge --ff-only "$winner_br" >/dev/null 2>&1 || git reset --hard "$winner_br" >/dev/null 2>&1
  else
    echo "   ⚠  no productive agent this cycle"
  fi

  # Cleanup: remove worktrees and scratch branches.
  for i in "${!AGENTS_CMDS[@]}"; do
    [ -z "${WT[$i]:-}" ] || git worktree remove "${WT[$i]}" --force >/dev/null 2>&1 || true
  done
  for i in "${!AGENTS_CMDS[@]}"; do
    [ -z "${BR[$i]:-}" ] || git branch -D "${BR[$i]}" >/dev/null 2>&1 || true
  done
  rm -rf "$wt_base" 2>/dev/null
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

  # Pick the agent for this turn (round-robin across configured slots).
  AGENT_IDX=$(( (CYCLE - 1) % ${#AGENTS_CMDS[@]} ))
  AGENT_LABEL="${AGENTS_LABELS[$AGENT_IDX]}"
  AGENT_CMD="${AGENTS_CMDS[$AGENT_IDX]}"
  # Legacy names that the dashboard report still references.
  MODEL="$AGENT_LABEL"

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

  if [ "$RING_MODE" = "parallel" ]; then
    echo "🎭 turn $CYCLE  ·  PARALLEL (all ${#AGENTS_CMDS[@]} agents)  ·  mode=$MODE"
    # For dashboard reporting we label the turn with the first agent.
    AGENT_LABEL="parallel(${#AGENTS_CMDS[@]})"
    MODEL="$AGENT_LABEL"
    report_status
    run_parallel_turn "$MODE" || echo "   (parallel turn failed; continuing)"
  else
    echo "🎭 turn $CYCLE  ·  agent=$AGENT_LABEL  ·  mode=$MODE"
    report_status
    run_turn "$MODE" "$AGENT_CMD" "$AGENT_LABEL" || echo "   (non-zero exit; continuing)"
  fi

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
