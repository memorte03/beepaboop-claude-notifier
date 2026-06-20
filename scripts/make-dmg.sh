#!/usr/bin/env bash
# Builds a drag-to-install disk image: dist/Boopr-<version>.dmg
#
# The recipient opens the .dmg, drags Boopr onto the Applications
# alias, and launches it — the app installs its own Claude Code hooks on first
# launch (see Bootstrap.swift), so there's no terminal step.
set -euo pipefail

command -v hdiutil >/dev/null 2>&1 || { echo "error: hdiutil not found (macOS only)" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPLAY_NAME="Boopr"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${REPO_ROOT}/Resources/Info.plist" 2>/dev/null || echo 0.1.0)"
DIST="${REPO_ROOT}/dist"
STAGE="${DIST}/dmg-stage"
DMG="${DIST}/Boopr-${VERSION}.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

"${REPO_ROOT}/scripts/build-app.sh" "${STAGE}/${DISPLAY_NAME}.app"

echo "→ adding Applications alias + README"
ln -s /Applications "${STAGE}/Applications"
cat > "${STAGE}/READ ME FIRST.txt" <<EOF
Boopr ${VERSION}

INSTALL
  1. Drag "Boopr" onto the Applications folder (here in this window).
  2. Open it from Applications (or Launchpad).

  The first time, macOS will warn that it's from an unidentified developer
  (this app isn't notarized by Apple). To allow it:
     - Go to  System Settings > Privacy & Security
     - Scroll down to the message about "Boopr" and click "Open Anyway".
  You only do this once.

REQUIREMENTS
  - macOS 14 (Sonoma) or newer
  - jq   ->  brew install jq   (Homebrew: https://brew.sh)
           The menu-bar bell will warn you if it's missing.

The app sets up its Claude Code hooks automatically on first launch. Grant
Accessibility and Automation when asked (menu-bar bell > Permissions) so
"Jump to session" can raise the right terminal window.
EOF

echo "→ creating disk image"
hdiutil create -volname "$DISPLAY_NAME" \
    -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

rm -rf "$STAGE"
echo
echo "✓ built: $DMG"
du -h "$DMG" | awk '{print "  size: " $1}'
echo "  send that .dmg to your friend — they drag the app to Applications and open it."
