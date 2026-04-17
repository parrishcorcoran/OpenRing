#!/usr/bin/env bash
# OpenRing installer. Audit me before piping to bash:
#   curl -fsSL https://raw.githubusercontent.com/parrishcorcoran/OpenRing/main/install.sh
#
# What this does:
#   1. Clones (or updates) parrishcorcoran/OpenRing into $OPENRING_HOME
#      (default: ~/.openring).
#   2. Makes openring.sh executable.
#   3. Symlinks it as `openring` into a bin dir on your PATH.
#
# What this does NOT do:
#   - Download any binary.
#   - Install any models, API keys, or dependencies.
#   - Modify your shell rc files.

set -euo pipefail

REPO_URL="${OPENRING_REPO:-https://github.com/parrishcorcoran/OpenRing.git}"
OPENRING_HOME="${OPENRING_HOME:-$HOME/.openring}"

# Pick a bin dir that's already on PATH and writable without sudo.
pick_bin_dir() {
  for d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
    case ":$PATH:" in
      *":$d:"*)
        if [ -d "$d" ] && [ -w "$d" ]; then
          echo "$d"; return 0
        fi
        if [ ! -d "$d" ] && mkdir -p "$d" 2>/dev/null; then
          echo "$d"; return 0
        fi
        ;;
    esac
  done
  return 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ Missing required command: $1" >&2
    exit 1
  }
}

require git

echo "📥 Installing OpenRing into $OPENRING_HOME"
if [ -d "$OPENRING_HOME/.git" ]; then
  echo "   Existing install detected. Pulling latest."
  git -C "$OPENRING_HOME" pull --ff-only
else
  git clone --depth=1 "$REPO_URL" "$OPENRING_HOME"
fi

chmod +x "$OPENRING_HOME/openring.sh"

if BIN_DIR="$(pick_bin_dir)"; then
  ln -sf "$OPENRING_HOME/openring.sh" "$BIN_DIR/openring"
  echo "🔗 Linked $BIN_DIR/openring -> $OPENRING_HOME/openring.sh"
  LAUNCH_HINT="openring"
else
  echo "⚠️  Could not find a writable bin dir on \$PATH."
  echo "   Add one of these to your PATH, or run the script directly:"
  echo "     $OPENRING_HOME/openring.sh"
  LAUNCH_HINT="$OPENRING_HOME/openring.sh"
fi

cat <<EOF

✅ OpenRing installed.

Next:
  1. Install opencode (https://opencode.ai) and run 'opencode auth login' per provider.
  2. In your project:
       cp $OPENRING_HOME/AGENTS.md.template     ./AGENTS.md
       cp $OPENRING_HOME/GOAL.md.template       ./GOAL.md
       cp $OPENRING_HOME/WHITEBOARD.md.template ./WHITEBOARD.md
       cp -r $OPENRING_HOME/.opencode           ./
     Then edit AGENTS.md (constitution + memory) and GOAL.md (what to do).
  3. Run:  $LAUNCH_HINT
  4. Review diffs before merging. The Ring commits on its own.

Uninstall:
  rm -rf "$OPENRING_HOME" && rm -f "\$(command -v openring 2>/dev/null)"
EOF
