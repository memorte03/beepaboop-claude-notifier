#!/usr/bin/env bash
# Sends a test notification targeting a tmux pane, so you can verify the
# "Open session" jump. Usage:
#   scripts/test-jump.sh [pane-id]     # default: first pane running claude
set -euo pipefail

PORT="${BEEPABOOP_PORT:-7891}"
TOKEN="$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/beepaboop/token" 2>/dev/null || true)"
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

curl -s -X POST "http://127.0.0.1:${PORT}/notify" -H 'Content-Type: application/json' -H "X-Beepaboop-Token: ${TOKEN}" -d "$(jq -nc \
    --arg pane "$pane" --arg session "$session" --arg window "$window" \
    --arg socket "$SOCKET" --arg bin "$TMUX_BIN" \
    '{
        id: ("jump-test-" + ($pane | ltrimstr("%"))),
        kind: "stop",
        title: ("Jump test → session " + $session + ", pane " + $pane),
        context: "Click Open session: the right Ghostty window should come forward (even across Spaces) with this pane focused.",
        repoName: "beepaboop",
        sessionId: "jump-test",
        terminalApp: "com.mitchellh.ghostty",
        tmuxSession: $session,
        tmuxPane: $pane,
        tmuxWindowId: $window,
        tmuxSocket: $socket,
        tmuxBin: $bin
    }')"
echo " -> sent"
