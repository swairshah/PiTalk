#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MARKETPLACE="claudetalk"
PLUGIN="claude-talk@${MARKETPLACE}"
SCOPE="user"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-claude-talk.sh <install|uninstall>

  install     Install ClaudeTalk from this checkout for the current user
  uninstall   Remove ClaudeTalk and its local marketplace registration

PiTalk.app is not installed or removed by this script. Run the app from this
checkout with ./run-dev.sh, or install it separately with Homebrew.
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: '$1' is required but was not found on PATH." >&2
    exit 1
  fi
}

plugin_is_installed() {
  "$CLAUDE_BIN" plugin list --json 2>/dev/null | python3 -c '
import json, sys
plugin_id, scope = sys.argv[1:]
try:
    plugins = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
installed = any(
    item.get("id") == plugin_id and item.get("scope") == scope
    for item in plugins
)
raise SystemExit(0 if installed else 1)
' "$PLUGIN" "$SCOPE"
}

remove_plugin() {
  if plugin_is_installed; then
    "$CLAUDE_BIN" plugin uninstall "$PLUGIN" --scope "$SCOPE"
  fi
}

remove_marketplace() {
  "$CLAUDE_BIN" plugin marketplace remove "$MARKETPLACE" --scope "$SCOPE" >/dev/null 2>&1 || true
}

cleanup_runtime_files() {
  local pid_file="/tmp/loqui-inbox-watcher.pid"
  if [[ -f "$pid_file" ]]; then
    local watcher_pid
    watcher_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ "$watcher_pid" =~ ^[0-9]+$ ]] && ps -p "$watcher_pid" -o command= 2>/dev/null | grep -q "inbox-watcher.sh"; then
      kill "$watcher_pid" 2>/dev/null || true
    fi
  fi
  rm -f \
    /tmp/loqui-inbox-watcher.pid \
    /tmp/loqui-tts-debug.log \
    /tmp/loqui-tts-flushed.json \
    /tmp/loqui-tts-spoken.json \
    /tmp/loqui-tts-state.json
}

install_plugin() {
  require_command "$CLAUDE_BIN"
  require_command python3

  # Re-registering guarantees the marketplace points at this checkout, even
  # when an older standalone ClaudeTalk marketplace was installed previously.
  remove_plugin
  remove_marketplace
  "$CLAUDE_BIN" plugin marketplace add "$REPO_ROOT" --scope "$SCOPE"
  "$CLAUDE_BIN" plugin install "$PLUGIN" --scope "$SCOPE" --yes

  cat <<EOF

ClaudeTalk installed from:
  $REPO_ROOT/Extensions/claude-talk

Start the local app with:
  $REPO_ROOT/run-dev.sh

Restart Claude Code, then run /claude-talk:tts-status to verify the connection.
EOF
}

uninstall_plugin() {
  require_command "$CLAUDE_BIN"
  require_command python3

  remove_plugin
  remove_marketplace
  cleanup_runtime_files
  echo "ClaudeTalk uninstalled. PiTalk.app was left unchanged."
}

case "${1:-}" in
  install) install_plugin ;;
  uninstall) uninstall_plugin ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
