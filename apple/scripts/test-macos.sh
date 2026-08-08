#!/bin/bash
# Run the PocketDJ test suite on macOS.
#
# macOS Gatekeeper blocks unsigned apps + XCUITest runners ("damaged"), and the
# project builds unsigned (no paid team needed). So we split build from run and
# ad-hoc sign the products in between:
#   build-for-testing  →  codesign --sign -  →  test-without-building
#
# Ad-hoc signing (--sign -) is the RIGHT path here, not a stopgap: it needs no
# provisioning profile and no device registration. The "real cert" route
# (`xcodebuild test -allowProvisioningUpdates`) does NOT work headlessly on this
# Mac — it fails because the iMac UDID isn't registered in the Developer portal
# and there's no Mac dev profile for com.levi.pocketdj. So this dance stays.
#
# First-run note: if a UI run dies with "Timed out while enabling automation
# mode", that's a one-time macOS Automation/Accessibility (TCC) permission for
# the test runner — grant it once and re-run; it is NOT a signing problem.
#
# Usage:
#   bash scripts/test-macos.sh                       # full suite, default derived dir
#   bash scripts/test-macos.sh build-mactest         # full suite, explicit derived dir
#   bash scripts/test-macos.sh -only-testing:…       # scoped run, default derived dir
#   bash scripts/test-macos.sh build-mactest -only-testing:PocketDJUITests/BrowseUITests
#
# The first arg is taken as the derivedDataPath ONLY when it doesn't start with
# "-"; any remaining args (e.g. -only-testing:…, -resultBundlePath …) pass
# straight through to `test-without-building`, so scoped macOS UI runs work
# without hand-running the build-for-testing / codesign / test dance.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DERIVED="build-mactest"
if [[ $# -gt 0 && "$1" != -* ]]; then
  DERIVED="$1"; shift
fi
PASSTHROUGH=("$@")   # forwarded verbatim to test-without-building (e.g. -only-testing:…)

echo "▶ build-for-testing (macOS, unsigned)…"
# Override the project's automatic signing → build unsigned, then ad-hoc sign
# below. (See the header: `-allowProvisioningUpdates` can't replace this on a Mac
# whose UDID isn't registered + has no com.levi.pocketdj profile.)
xcodebuild build-for-testing -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO >/dev/null

PRODUCTS="$DERIVED/Build/Products/Debug"

# STABLE-identity signing when the CI keychain is available (TCC permanence): an
# ad-hoc signature changes on every rebuild, so macOS treats each build as a NEW
# app and re-prompts privacy grants (the speech-permission Allow loop). The CI
# keychain's Apple Development cert gives every build the SAME identity, so one
# Allow sticks forever. Falls back to ad-hoc when the keychain/cert is absent.
IDENTITY="-"
if [ -f "$HOME/.config/pocketdj/ci-keychain-pass" ]; then
  security unlock-keychain -p "$(cat "$HOME/.config/pocketdj/ci-keychain-pass")" pocketdj-ci.keychain-db 2>/dev/null || true
  FOUND=$(security find-identity -v -p codesigning pocketdj-ci.keychain-db 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')
  if [ -n "$FOUND" ]; then IDENTITY="$FOUND"; fi
fi
echo "▶ signing test products in $PRODUCTS (identity: $IDENTITY)…"
find "$PRODUCTS" -maxdepth 1 \( -name "*.app" -o -name "*.xctest" \) -print0 \
  | while IFS= read -r -d '' bundle; do
      xattr -dr com.apple.quarantine "$bundle" 2>/dev/null || true
      codesign --force --deep --sign "$IDENTITY" "$bundle" >/dev/null 2>&1 \
        || codesign --force --deep --sign - "$bundle" >/dev/null 2>&1
      echo "  signed $(basename "$bundle")"
    done

# Kill any stray PocketDJ instance — a second instance of the same bundle id
# steals focus from the XCUITest-launched app, so keyboard commands + taps never
# reach the window under test. (Also: keep hands off the keyboard during the run.)
echo "▶ closing any running macOS PocketDJ…"
osascript -e 'tell application "PocketDJ" to quit' 2>/dev/null || true
# Kill ONLY the macOS app. A bare `killall PocketDJ` also matches the process the
# iOS **Simulator** runs under the same executable name, so it silently destroys a
# concurrent iOS XCUITest suite on another agent's simulator. The victim's log then
# reads "Application com.levi.pocketdj is not running" / "Lost connection to the
# application" / "Test crashed with signal kill" — indistinguishable from a real
# product regression, and it cost hours of misdiagnosis. Match on the full macOS
# bundle path instead; simulator processes live under CoreSimulator/Devices/… and
# therefore never match.
pkill -f '/Contents/MacOS/PocketDJ$' 2>/dev/null || true
sleep 1

echo "▶ test-without-building (macOS)…"
# `${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}` expands to nothing when the array is
# empty — safe under `set -u` on bash 3.2 (macOS), where a bare "${arr[@]}"
# would otherwise trip "unbound variable".
xcodebuild test-without-building -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
