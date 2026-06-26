#!/bin/sh
# Boopr PreToolUse hook for AskUserQuestion / ExitPlanMode.
# Thin wrapper: tells the app Claude is asking the user something, so it surfaces
# a notify-with-jump (no Approve/Deny — it's a question, not a permission). Emits
# no stdout, so the interactive prompt renders normally. No dependencies.
B="$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/boopr/bin" 2>/dev/null)"
[ -x "$B" ] || B="/Applications/Boopr.app/Contents/MacOS/Boopr"
[ -x "$B" ] || exit 0   # app not installed → no-op, never block the prompt
exec "$B" __hook ask
