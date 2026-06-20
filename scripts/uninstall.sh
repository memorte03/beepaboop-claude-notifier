#!/usr/bin/env bash
# Removes Boopr completely: app bundle, hook scripts, token/config,
# and the hook entries in ~/.claude/settings.json (other hooks are preserved).
set -euo pipefail

DISPLAY_NAME="Boopr"
APP_BUNDLE="/Applications/${DISPLAY_NAME}.app"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/boopr"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

echo "→ stopping app"
pkill -x Boopr 2>/dev/null || true   # exact name, not a command-line scan
sleep 0.3

echo "→ removing ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"

if [[ -f "$CLAUDE_SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
    echo "→ removing hook entries from ${CLAUDE_SETTINGS}"
    cp "$CLAUDE_SETTINGS" "${CLAUDE_SETTINGS}.bak"
    jq '
        def drop_ours(list):
            (list // []) | map(select(
                ((.hooks // []) | any(.command | test("boopr"))) | not
            ));
        if .hooks then
            .hooks.Stop         = drop_ours(.hooks.Stop)
          | .hooks.Notification = drop_ours(.hooks.Notification)
          | .hooks.PreToolUse   = drop_ours(.hooks.PreToolUse)
          | .hooks |= with_entries(select(.value != []))
          | if .hooks == {} then del(.hooks) else . end
        else . end
    ' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp"
    mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS"
fi

echo "→ removing ${CONFIG_DIR} (hooks + token)"
rm -rf "$CONFIG_DIR"

cat <<EOF

uninstalled. Leftovers you may want to clean manually:
  - System Settings → Privacy & Security → Accessibility / Automation entries
  - System Settings → General → Login Items (if Launch at Login was enabled)
EOF
