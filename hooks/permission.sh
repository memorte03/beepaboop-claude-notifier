#!/bin/sh
# Boopr PreToolUse hook (BLOCKING).
# Thin wrapper: hands the event to the Boopr binary, which posts to the overlay,
# waits for Approve/Deny, and prints the permissionDecision JSON. If the app
# isn't installed/running it falls back to "ask" so Claude shows its native
# prompt. No jq, no other dependencies.
B="$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/boopr/bin" 2>/dev/null)"
[ -x "$B" ] || B="/Applications/Boopr.app/Contents/MacOS/Boopr"
[ -x "$B" ] || exit 0   # app not installed → defer to Claude's native prompt
exec "$B" __hook permission
