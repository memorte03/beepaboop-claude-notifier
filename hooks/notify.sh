#!/bin/sh
# Boopr Stop/Notification hook.
# Thin wrapper: hands the event to the Boopr binary, which does everything
# in-process (JSON, terminal detection, HTTP) — no jq, no other dependencies.
# Install as a Stop / Notification hook in ~/.claude/settings.json.
B="$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/boopr/bin" 2>/dev/null)"
[ -x "$B" ] || B="/Applications/Boopr.app/Contents/MacOS/Boopr"
[ -x "$B" ] || exit 0   # app not installed → no-op, never break Claude
exec "$B" __hook notify
