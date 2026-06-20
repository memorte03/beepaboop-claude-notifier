#!/usr/bin/env bash
# Fast redeploy for iterating on the app itself: build, copy the binary into the
# installed bundle, RE-SIGN with the stable identifier, and relaunch.
#
# Always use this (or install.sh) — never a bare `cp` into the bundle. A plain
# copy leaves the linker's default ad-hoc signature (Identifier=Boopr),
# which no longer matches the com.memorte03.boopr identity that macOS TCC
# granted Accessibility/Automation to, silently breaking jump-to-session.
#
# Unlike install.sh this skips the hooks/settings steps, so it's quick.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Boopr"
BUNDLE="/Applications/Boopr.app"
BUNDLE_ID="com.memorte03.boopr"

cd "$REPO_ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"

pkill -x "${APP_NAME}" 2>/dev/null || true   # exact name, not a command-line scan
sleep 0.5
cp "$BIN" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
# shellcheck source=lib-sign.sh
source "${REPO_ROOT}/scripts/lib-sign.sh"
cn_sign_bundle "$BUNDLE" "$BUNDLE_ID"
open "$BUNDLE"
echo "relaunched ${BUNDLE}"
