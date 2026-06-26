#!/usr/bin/env bash
# Removes Boopr completely: app bundle, hook scripts, token/config,
# and the hook entries in ~/.claude/settings.json (other hooks are preserved).
set -euo pipefail

DISPLAY_NAME="Boopr"
APP_BUNDLE="/Applications/${DISPLAY_NAME}.app"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/boopr"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

# Strip boopr's settings.json entries first, while the app binary still exists —
# it removes them via Foundation (no jq), backing up settings.json. Other hooks
# are preserved.
APP_BIN="${APP_BUNDLE}/Contents/MacOS/Boopr"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    if [[ -x "$APP_BIN" ]]; then
        echo "→ removing hook entries from ${CLAUDE_SETTINGS}"
        "$APP_BIN" __unwire || echo "   ⚠ couldn't update it — remove the \"boopr\" hook entries manually." >&2
    else
        echo "   ⚠ Boopr.app not found — remove the \"boopr\" hook entries from ${CLAUDE_SETTINGS} manually." >&2
    fi
fi

echo "→ stopping app"
pkill -x Boopr 2>/dev/null || true   # exact name, not a command-line scan
sleep 0.3

echo "→ removing ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"

echo "→ removing ${CONFIG_DIR} (hooks + token)"
rm -rf "$CONFIG_DIR"

cat <<EOF

uninstalled. Leftovers you may want to clean manually:
  - System Settings → Privacy & Security → Accessibility / Automation entries
  - System Settings → General → Login Items (if Launch at Login was enabled)
EOF
