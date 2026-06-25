#!/usr/bin/env bash
# Builds a Developer-ID-signed, Apple-notarized, stapled .dmg for distribution —
# it opens on anyone's Mac with no Gatekeeper warning.
#
# One-time setup (Developer ID certificate + notarization credentials) is in
# docs/RELEASING.md. After that, this whole thing is a single command.
#
# Overrides via env:
#   DEV_ID="Developer ID Application: Name (TEAMID)"   # else auto-detected
#   NOTARY_PROFILE=boopr-notary                          # notarytool keychain profile
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Boopr"
DISPLAY_NAME="Boopr"
ENTITLEMENTS="$REPO_ROOT/Resources/boopr.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-boopr-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 0.1.0)"
DIST="$REPO_ROOT/dist"
STAGE="$DIST/dmg-stage"
APP="$STAGE/$DISPLAY_NAME.app"
DMG="$DIST/$DISPLAY_NAME-$VERSION.dmg"

# ── preflight ────────────────────────────────────────────────────────────────
for tool in xcrun codesign hdiutil ditto; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found" >&2; exit 1; }
done

DEV_ID="${DEV_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [[ -z "$DEV_ID" ]]; then
    echo "error: no 'Developer ID Application' certificate in the keychain." >&2
    echo "       create one first — see docs/RELEASING.md (§ 1. Developer ID certificate)." >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool keychain profile '$NOTARY_PROFILE' isn't set up." >&2
    echo "       run the store-credentials step in docs/RELEASING.md (§ 2)." >&2
    exit 1
fi

echo "→ identity:  $DEV_ID"
echo "→ notary:    $NOTARY_PROFILE"
echo "→ version:   $VERSION"

# ── build the universal app bundle (build-app.sh ad-hoc signs; we re-sign next) ─
rm -rf "$DIST"
mkdir -p "$STAGE"
"$REPO_ROOT/scripts/build-app.sh" "$APP"

# ── sign with Developer ID + hardened runtime + entitlements + secure timestamp ─
echo "→ signing app (Developer ID, hardened runtime)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEV_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# ── notarize the app, then staple the ticket into the bundle ──────────────────
echo "→ notarizing app (uploads to Apple; --wait blocks until done)…"
APP_ZIP="$DIST/$DISPLAY_NAME-app.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
xcrun stapler staple "$APP"
rm -f "$APP_ZIP"

# ── assemble + create the DMG (containing the stapled app) ────────────────────
echo "→ building DMG"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME.txt" <<EOF
Boopr $VERSION — desktop notifications for Claude Code.

Drag Boopr onto the Applications folder, then open it. It installs its own
Claude Code hooks on first launch. Grant Accessibility and Automation when
asked (needed for "Jump to session").
EOF
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# ── sign + notarize + staple the DMG itself ──────────────────────────────────
echo "→ signing DMG"
codesign --force --timestamp --sign "$DEV_ID" "$DMG"
echo "→ notarizing DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
xcrun stapler staple "$DMG"

# ── verify ───────────────────────────────────────────────────────────────────
echo "→ verifying"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true
xcrun stapler validate "$DMG"
rm -rf "$STAGE"

echo
echo "✓ release DMG: $DMG"
du -h "$DMG" | awk '{print "  size: " $1}'
echo "  signed + notarized + stapled — opens with no Gatekeeper warning."
