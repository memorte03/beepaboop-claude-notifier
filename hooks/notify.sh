#!/usr/bin/env bash
# Fire-and-forget hook for Stop and Notification events.
# Install as a Stop / Notification hook in ~/.claude/settings.json.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=beepaboop-common.sh
source "$SCRIPT_DIR/beepaboop-common.sh"

event="$(cn_hook_event)"
case "$event" in
    Stop|SubagentStop)
        kind="stop"
        title="Claude is done"
        context="$(cn_trim "$(cn_message)")"
        ;;
    Notification)
        kind="idle"
        title="Claude is waiting for you"
        context="$(cn_trim "$(cn_message)")"
        ;;
    *)
        kind="info"
        title="Claude: $event"
        context="$(cn_trim "$(cn_message)")"
        ;;
esac

payload="$(cn_build_payload "$(cn_uuid)" "$kind" "$title" "$context")"

curl --silent --show-error --max-time 2 \
     -X POST "$CN_URL/notify" \
     -H 'Content-Type: application/json' \
     -H "X-Beepaboop-Token: ${CN_TOKEN}" \
     -d "$payload" >/dev/null 2>&1 || true

exit 0
