#!/bin/sh
# Boopr UserPromptSubmit hook.
# Thin wrapper: tells the app the user just typed in this session, so its pill
# (if any) clears — the deterministic fallback for when tmux focus detection
# can't tell. Emits no stdout, so it never alters the prompt. No dependencies.
B="$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/boopr/bin" 2>/dev/null)"
[ -x "$B" ] || B="/Applications/Boopr.app/Contents/MacOS/Boopr"
[ -x "$B" ] || exit 0   # app not installed → no-op, never block the prompt
exec "$B" __hook active
