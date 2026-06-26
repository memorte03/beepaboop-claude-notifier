#!/usr/bin/env bash
# Builds a self-contained, sendable distribution of Boopr:
#   dist/Boopr-<version>.zip
#
# The ZIP contains a prebuilt universal .app (no Swift toolchain needed on the
# recipient's Mac), the hook scripts, and a double-clickable installer that
# wires everything up. Send that ZIP to a friend.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Boopr"
DISPLAY_NAME="Boopr"
BUNDLE_ID="com.memorte03.boopr"
cd "$REPO_ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 0.1.0)"
DIST="${REPO_ROOT}/dist"
STAGE="${DIST}/${DISPLAY_NAME}"
APP="${STAGE}/${DISPLAY_NAME}.app"

rm -rf "$DIST"
mkdir -p "$STAGE/support"
"${REPO_ROOT}/scripts/build-app.sh" "$APP"

echo "→ staging support files (signing helpers)"
# Hooks are bundled inside the .app and installed by it on first launch, so the
# installer doesn't ship or copy them separately.
cp "${REPO_ROOT}/scripts/lib-sign.sh" "${REPO_ROOT}/scripts/make-signing-cert.sh" "${STAGE}/support/"

echo "→ writing Install.command"
cat > "${STAGE}/Install.command" <<'INSTALLER'
#!/bin/bash
# Installs Boopr: copies the app to /Applications, wires the Claude
# Code hooks, and launches it. Safe to re-run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT="$HERE/support"
APP_SRC="$HERE/Boopr.app"
APP_DST="/Applications/Boopr.app"
BUNDLE_ID="com.memorte03.boopr"
SETTINGS="$HOME/.claude/settings.json"

echo "Installing Boopr…"

echo "→ copying app to /Applications"
pkill -x Boopr 2>/dev/null || true
sleep 0.4
rm -rf "$APP_DST"
# ditto overwrites cleanly — unlike `cp -R`, it won't nest the bundle inside an
# existing target if the rm above raced with Launch Services reopening the app.
ditto "$APP_SRC" "$APP_DST"
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

# Sign with a stable per-machine certificate so macOS keeps the Accessibility /
# Automation permissions across relaunches; fall back to ad-hoc if that fails.
# shellcheck source=/dev/null
source "$SUPPORT/lib-sign.sh"
if [[ "$(cn_sign_identity)" == "-" ]]; then
    echo "→ creating a local signing certificate (keeps permissions from resetting)"
    echo "  macOS may ask for your login password — that's expected."
    bash "$SUPPORT/make-signing-cert.sh" || echo "  (continuing with ad-hoc signing)"
fi
echo "→ signing the app"
cn_sign_bundle "$APP_DST" "$BUNDLE_ID"

# The app installs its wrapper hooks and merges its entries into settings.json
# itself on first launch (pure Foundation — no jq), backing up the original.
echo "→ launching (Boopr installs its hooks + wires $SETTINGS on first run)"
open "$APP_DST"

cat <<EOF

Done! Boopr is in your menu bar (the bell icon).

One-time setup:
  - Grant Accessibility and Automation when prompted (or from the menu
    bar bell → Permissions). They're needed for "Jump to session".
  - Menu bar bell → "Launch at Login" to start it automatically.

Notifications appear when Claude Code finishes, waits, or asks permission.
EOF
read -r -p "Press return to close." _ || true
INSTALLER
chmod +x "${STAGE}/Install.command"

echo "→ writing README.txt"
cat > "${STAGE}/README.txt" <<EOF
Boopr — native macOS overlay for Claude Code
======================================================

A menu-bar app that pops a notification when Claude Code finishes, needs
input, or asks for permission — on whatever Space you're currently on —
with Approve/Deny and a one-click jump to the right terminal session.

REQUIREMENTS
  - macOS 14 (Sonoma) or newer
  - Claude Code
  - Best experience: tmux + Ghostty 1.3+ (for cross-Space jump-to-session)

INSTALL
  1. Open Terminal, type "bash " (with a space), then DRAG the file
     "Install.command" (next to this README) into the Terminal window
     and press Return.
       - Running it this way avoids the macOS "unidentified developer"
         warning. (Double-clicking works too, but you'll have to
         right-click -> Open, or approve it in System Settings ->
         Privacy & Security.)
  2. Follow the prompts. Grant Accessibility + Automation when asked.

This app isn't from the App Store and isn't notarized by Apple, so macOS
is cautious about it — that's why the installer clears the quarantine flag
and signs it locally on your machine.

UNINSTALL
  Delete /Applications/Boopr.app and the folder
  ~/.config/boopr, and remove the "boopr" hook entries
  from ~/.claude/settings.json (a backup was saved as settings.json.bak).

Version ${VERSION}
EOF

echo "→ zipping"
ZIP="${DIST}/Boopr-${VERSION}.zip"
( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "${DISPLAY_NAME}" "$ZIP" )

echo
echo "✓ built: $ZIP"
echo "  architectures: $(lipo -archs "${APP}/Contents/MacOS/${APP_NAME}")"
du -h "$ZIP" | awk '{print "  size: " $1}'
echo "  send that .zip to your friend; they follow the steps in README.txt."
