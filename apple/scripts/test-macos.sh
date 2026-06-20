#!/bin/bash
# Run the PocketDJ test suite on macOS.
#
# macOS Gatekeeper blocks unsigned apps + XCUITest runners ("damaged"), and the
# project builds unsigned (no paid team needed). So we split build from run and
# ad-hoc sign the products in between:
#   build-for-testing  →  codesign --sign -  →  test-without-building
#
# Once a real signing team is configured (DEVELOPMENT_TEAM in project.yml +
# automatic signing), this dance is unnecessary — a plain `xcodebuild test`
# works. Until then, this keeps macOS UI tests green locally.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DERIVED="${1:-build-mactest}"

echo "▶ build-for-testing (macOS, unsigned)…"
# Override the project's automatic signing → build unsigned, then ad-hoc sign
# below. (Once a Mac Development cert exists in the login keychain, you can skip
# this whole script and just run: xcodebuild test -allowProvisioningUpdates.)
xcodebuild build-for-testing -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO >/dev/null

PRODUCTS="$DERIVED/Build/Products/Debug"
echo "▶ ad-hoc signing test products in $PRODUCTS …"
find "$PRODUCTS" -maxdepth 1 \( -name "*.app" -o -name "*.xctest" \) -print0 \
  | while IFS= read -r -d '' bundle; do
      xattr -dr com.apple.quarantine "$bundle" 2>/dev/null || true
      codesign --force --deep --sign - "$bundle" >/dev/null 2>&1
      echo "  signed $(basename "$bundle")"
    done

# Kill any stray PocketDJ instance — a second instance of the same bundle id
# steals focus from the XCUITest-launched app, so keyboard commands + taps never
# reach the window under test. (Also: keep hands off the keyboard during the run.)
echo "▶ closing any running PocketDJ…"
osascript -e 'tell application "PocketDJ" to quit' 2>/dev/null || true
killall PocketDJ 2>/dev/null || true
sleep 1

echo "▶ test-without-building (macOS)…"
xcodebuild test-without-building -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED"
