#!/usr/bin/env bash
# openring.sh — the clock and the referee.
#
# opencode is the agent. This script only does what opencode can't do on its
# own: schedule unattended cycles, force role rotation on a timer, detect
# tree-level stalls, and hot-swap to a local Ollama model when a plan provider
# rate-limits or errors.
#
# Optional: pair with the Vercel dashboard for remote status + whiteboard
# control by setting OPENRING_DASHBOARD_URL + OPENRING_DASHBOARD_TOKEN.
#
# Requirements: opencode installed and authenticated (opencode auth login),
# AGENTS.md present in cwd, and the .opencode/ preset copied in.

set -uo pipefail

# ---------- Config ----------
ARCHITECT_MODEL="${ARCHITECT_MODEL:-anthropic/claude-sonnet-4-5}"
ADVERSARY_MODEL="${ADVERSARY_MODEL:-github-copilot/gpt-5}"
GRINDER_MODEL="${GRINDER_MODEL:-google/gemini-2.5-pro}"
OLLAMA_MODEL="${OLLAMA_MODEL:-}"
OLLAMA_IN_ROTATION="${OLLAMA_IN_ROTATION:-0}"

MAX_CYCLES="${MAX_CYCLES:-15}"
CHAOS_RATE="${CHAOS_RATE:-20}"
STALL_LIMIT="${STALL_LIMIT:-3}"
COOLDOWN="${COOLDOWN:-5}"
LOG_DIR="${LOG_DIR:-.openring/logs}"

# Remote dashboard (optional). If URL is unset, all remote calls are skipped.
DASH_URL="${OPENRING_DASHBOARD_URL:-}"
DASH_TOKEN="${OPENRING_DASHBOARD_TOKEN:-}"
REMOTE_BRANCH="${OPENRING_REMOTE_BRANCH:-}"  # set to e.g. "origin main" to git pull/push each cycle

WHITEBOARD_FILE="WHITEBOARD.md"

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
HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1

echo "🚀 OpenRing starting in $(pwd)"
echo "   Architect: $ARCHITECT_MODEL"
echo "   Adversary: $ADVERSARY_MODEL"
echo "   Grinder:   $GRINDER_MODEL"
[ -n "$OLLAMA_MODEL" ] && echo "   Ollama:    $OLLAMA_MODEL $([ "$OLLAMA_IN_ROTATION" = 1 ] && echo '(in rotation)' || echo '(hot-swap fallback)')"
[ -n "$DASH_URL" ] && echo "   Dashboard: $DASH_URL"
[ -n "$REMOTE_BRANCH" ] && echo "   Remote:    pulling/pushing $REMOTE_BRANCH each cycle"

# ---------- Dashboard helpers ----------
dash() {
  # dash METHOD PATH [json-body] — no-op if not configured, silent on network errors.
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

json_str() {
  # Portable JSON-string escape via python. Falls back to a dumb escape.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'
  else
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g' | awk '{print "\""$0"\""}'
  fi
}

report_status() {
  [ -z "$DASH_URL" ] && return 0
  local sha; sha="$(git rev-parse --short HEAD 2>/dev/null || echo "")"
  local tree_clean="true"; [ -n "$(git status --porcelain)" ] && tree_clean="false"
  local body
  body=$(cat <<EOF
{"cycle":$CYCLE,"role":"$ROLE","model":"$MODEL","last_commit_sha":"$sha","stall_count":$STALL_COUNT,"tree_clean":$tree_clean}
EOF
)
  dash POST /api/ingest "$body" >/dev/null
}

report_tail() {
  [ -z "$DASH_URL" ] && return 0
  local log="$1"
  [ -f "$log" ] || return 0
  local lines_json
  # Take last 80 lines, pass through json_str line-by-line, wrap in array.
  lines_json=$(tail -n 80 "$log" | awk 'BEGIN{first=1}{
    gsub(/\\/,"\\\\");
    gsub(/"/,"\\\"");
    gsub(/\t/,"\\t");
    if (first) {first=0} else {printf ","}
    printf "\"%s\"", $0
  }')
  local body="{\"cycle\":$CYCLE,\"role\":\"$ROLE\",\"lines\":[$lines_json]}"
  dash POST /api/tail "$body" >/dev/null
}

poll_control() {
  [ -z "$DASH_URL" ] && echo "" && return 0
  dash GET /api/control
}

clear_control() {
  [ -z "$DASH_URL" ] && return 0
  dash POST /api/control '{"command":null}' >/dev/null
}

sync_whiteboard_in() {
  # KV → local file. If dashboard whiteboard is newer, overwrite local file.
  [ -z "$DASH_URL" ] && return 0
  local remote; remote=$(dash GET /api/whiteboard)
  [ -z "$remote" ] && return 0
  # Extract content + updated_at using python (robust) or jq if available.
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
  # local file → KV. Called after Architect cycle, so the dashboard reflects
  # "cleared" state when the architect addresses the instruction.
  [ -z "$DASH_URL" ] && return 0
  [ -f "$WHITEBOARD_FILE" ] || return 0
  local content; content=$(cat "$WHITEBOARD_FILE")
  local escaped; escaped=$(printf '%s' "$content" | json_str)
  dash POST /api/whiteboard "{\"content\":$escaped,\"source\":\"loop\"}" >/dev/null
}

whiteboard_hard_stop() {
  # Returns the hard-stop phrase if the whiteboard contains one on its own line.
  [ -f "$WHITEBOARD_FILE" ] || return 0
  local below; below=$(awk '/Your instruction goes below this line/{found=1;next} found' "$WHITEBOARD_FILE" 2>/dev/null)
  [ -z "$below" ] && below=$(cat "$WHITEBOARD_FILE")
  if echo "$below" | grep -qE '^\s*STOP\s*$'; then echo "STOP"; return 0; fi
  if echo "$below" | grep -qE '^\s*PAUSE\s*$'; then echo "PAUSE"; return 0; fi
  if echo "$below" | grep -qE '^\s*FORCE ADVERSARY\s*$'; then echo "FORCE-ADVERSARY"; return 0; fi
}

# ---------- opencode runner ----------
run_agent() {
  local role="$1" model="$2" log="$LOG_DIR/cycle-${CYCLE}-${role}.log"
  local prompt="@${role} Proceed per AGENTS.md. If WHITEBOARD.md has an instruction, that supersedes the current objective; address it and wipe the whiteboard when done. Otherwise pick the next unchecked goal. Commit with '${role}:' prefix, append a bullet to Cycle Log."

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
SUSPEND_ADVERSARY_NEXT=0
PAUSED=0

while (( CYCLE < MAX_CYCLES )); do
  CYCLE=$((CYCLE + 1))
  echo "════════ Cycle $CYCLE / $MAX_CYCLES ════════"

  # Pull from remote if configured (picks up GitHub-edited WHITEBOARD.md).
  if [ -n "$REMOTE_BRANCH" ]; then
    # shellcheck disable=SC2086
    git pull --ff-only $REMOTE_BRANCH >/dev/null 2>&1 || echo "   (git pull failed; continuing)"
  fi

  # Pull whiteboard from dashboard if newer.
  sync_whiteboard_in

  # Hard-stop phrases in whiteboard.
  HS="$(whiteboard_hard_stop)"
  case "$HS" in
    STOP) echo "🛑 Whiteboard STOP. Exiting."; break ;;
    PAUSE) echo "⏸  Whiteboard PAUSE. Sleeping $COOLDOWN s and re-checking."; sleep "$COOLDOWN"; CYCLE=$((CYCLE - 1)); continue ;;
    FORCE-ADVERSARY) FORCE_ADVERSARY_FROM_WB=1 ;;
    *) FORCE_ADVERSARY_FROM_WB=0 ;;
  esac

  # Pull remote control command.
  CTRL=$(poll_control)
  CTRL_CMD=""
  if [ -n "$CTRL" ]; then
    if command -v python3 >/dev/null 2>&1; then
      CTRL_CMD=$(printf '%s' "$CTRL" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("command") or "")' 2>/dev/null)
    fi
  fi
  case "$CTRL_CMD" in
    stop) echo "🛑 Control STOP. Exiting."; clear_control; break ;;
    pause) echo "⏸  Control PAUSE."; PAUSED=1 ;;
    resume) echo "▶  Control RESUME."; PAUSED=0; clear_control ;;
    skip) echo "⏭  Control SKIP."; clear_control; CYCLE=$((CYCLE - 1)); sleep "$COOLDOWN"; continue ;;
    force-adversary) FORCE_ADVERSARY_FROM_WB=1; clear_control ;;
  esac
  if [ "$PAUSED" = 1 ]; then sleep "$COOLDOWN"; CYCLE=$((CYCLE - 1)); continue; fi

  # Role selection.
  if [ "$FORCE_ADVERSARY_FROM_WB" = 1 ]; then
    ROLE="adversary"; MODEL="$ADVERSARY_MODEL"
    echo "🚨 Forced Adversary (whiteboard / control)."
  elif [ "$SUSPEND_ADVERSARY_NEXT" = 1 ]; then
    SUSPEND_ADVERSARY_NEXT=0
    ROLE="architect"; MODEL="$ARCHITECT_MODEL"
    echo "🔧 Post-breaker: forcing Architect."
  elif (( RANDOM % 100 < CHAOS_RATE )); then
    ROLE="adversary"; MODEL="$ADVERSARY_MODEL"
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
  report_status
  run_agent "$ROLE" "$MODEL" || echo "   (non-zero exit; continuing)"

  # After Architect, sync whiteboard file → dashboard (reflects any clearing).
  [ "$ROLE" = "architect" ] && sync_whiteboard_out

  # Push any agent commits back to remote.
  if [ -n "$REMOTE_BRANCH" ]; then
    # shellcheck disable=SC2086
    git push $REMOTE_BRANCH >/dev/null 2>&1 || echo "   (git push failed; continuing)"
  fi

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

echo "🛑 Reached MAX_CYCLES=$MAX_CYCLES or STOP. Done."
