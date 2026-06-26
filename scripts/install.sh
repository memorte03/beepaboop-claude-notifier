#!/usr/bin/env bash
# Builds Boopr, packages it as a proper .app bundle, installs it into
# /Applications, copies the hook scripts to a stable location, and wires them
# into ~/.claude/settings.json. Idempotent: safe to re-run after updates.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Boopr"
DISPLAY_NAME="Boopr"
BUNDLE_ID="com.memorte03.boopr"
INSTALL_DIR="/Applications"
APP_BUNDLE="${INSTALL_DIR}/${DISPLAY_NAME}.app"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/boopr"
HOOKS_DIR="${CONFIG_DIR}/hooks"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
# Tools that surface an overlay Approve/Deny prompt. Adjust to taste, re-run.
PRETOOL_MATCHER="${BOOPR_PRETOOL_MATCHER:-Bash|Write|Edit|MultiEdit|NotebookEdit}"

# ── prerequisites ───────────────────────────────────────────────────────────
if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift toolchain not found — install Xcode or Command Line Tools" >&2
    exit 1
fi

cd "$REPO_ROOT"

echo "→ building release binary"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "build did not produce ${BIN_PATH}" >&2
    exit 1
fi

echo "→ stopping any running instance"
# -x matches the exact process name (covers both the installed and the in-place
# dev binary), unlike -f which scans the whole command line and could match an
# unrelated process (an editor, a tail) whose args end in that path.
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.3

echo "→ assembling bundle"
STAGING="$(mktemp -d)/${DISPLAY_NAME}.app"
mkdir -p "${STAGING}/Contents/MacOS" "${STAGING}/Contents/Resources"
cp "$BIN_PATH" "${STAGING}/Contents/MacOS/${APP_NAME}"
cp "${REPO_ROOT}/Resources/Info.plist" "${STAGING}/Contents/Info.plist"
if [[ -f "${REPO_ROOT}/Resources/AppIcon.icns" ]]; then
    cp "${REPO_ROOT}/Resources/AppIcon.icns" "${STAGING}/Contents/Resources/AppIcon.icns"
fi
# Bundle the hooks so the app can self-install them on first launch.
mkdir -p "${STAGING}/Contents/Resources/hooks"
cp "${REPO_ROOT}/hooks/"*.sh "${STAGING}/Contents/Resources/hooks/"
chmod +x "${STAGING}/Contents/MacOS/${APP_NAME}"

echo "→ installing to ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"
mv "$STAGING" "$APP_BUNDLE"
# Clear any quarantine attr so Gatekeeper doesn't flag it on first launch.
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

echo "→ signing (stable cert if available, else ad-hoc)"
# shellcheck source=lib-sign.sh
source "${REPO_ROOT}/scripts/lib-sign.sh"
cn_sign_bundle "$APP_BUNDLE" "$BUNDLE_ID"

# ── hooks + settings wiring ─────────────────────────────────────────────────
# The app installs the wrapper hooks into ${HOOKS_DIR} and merges its entries
# into settings.json itself on first launch (Bootstrap, pure Foundation — no
# jq), recording its own path so the hooks find it. We just launch it.
echo "→ launching (the app installs its hooks + wires ${CLAUDE_SETTINGS} on first run)"
open "$APP_BUNDLE"

cat <<EOF

installed:
  app:    ${APP_BUNDLE}
  hooks:  ${HOOKS_DIR} (installed by the app on first launch)
  config: ${CLAUDE_SETTINGS} (backup at ${CLAUDE_SETTINGS}.bak)

next steps:
  - grant Accessibility when prompted (and Automation on first jump)
  - menu bar → Boopr → "Launch at Login" to enable auto-start
  - permission prompts cover: ${PRETOOL_MATCHER}

uninstall any time with: scripts/uninstall.sh
EOF
