#!/usr/bin/env bash
# Sends a test notification targeting a tmux pane, so you can verify the
# "Open session" jump. Usage:
#   scripts/test-jump.sh [pane-id]     # default: first pane running claude
set -euo pipefail

PORT="${BOOPR_PORT:-7891}"
TOKEN="$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/boopr/token" 2>/dev/null || true)"
TMUX_BIN="$(command -v tmux)" || { echo "tmux not found — this test needs tmux" >&2; exit 1; }
SOCKET="$($TMUX_BIN display-message -p '#{socket_path}')"

pane="${1:-}"
if [[ -z "$pane" ]]; then
    pane="$($TMUX_BIN -S "$SOCKET" list-panes -a -F '#{pane_id} #{pane_current_command}' \
            | awk '$2 ~ /claude|node/ {print $1; exit}')"
fi
[[ -z "$pane" ]] && { echo "no claude pane found; pass a pane id (e.g. %4)" >&2; exit 1; }

session="$($TMUX_BIN -S "$SOCKET" display-message -p -t "$pane" '#{session_name}')"
window="$($TMUX_BIN -S "$SOCKET" display-message -p -t "$pane" '#{window_id}')"

echo "targeting pane $pane (session $session, window $window)"

# Build the payload without jq (the fields here are plain tmux ids/paths).
read -r -d '' PAYLOAD <<JSON || true
{
  "id": "jump-test-${pane#%}",
  "kind": "stop",
  "title": "Jump test → session ${session}, pane ${pane}",
  "context": "Click Open session: the right Ghostty window should come forward (even across Spaces) with this pane focused.",
  "repoName": "boopr",
  "sessionId": "jump-test",
  "terminalApp": "com.mitchellh.ghostty",
  "tmuxSession": "${session}",
  "tmuxPane": "${pane}",
  "tmuxWindowId": "${window}",
  "tmuxSocket": "${SOCKET}",
  "tmuxBin": "${TMUX_BIN}"
}
JSON

curl -s -X POST "http://127.0.0.1:${PORT}/notify" \
    -H 'Content-Type: application/json' -H "X-Boopr-Token: ${TOKEN}" -d "$PAYLOAD"
echo " -> sent"
