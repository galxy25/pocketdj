#!/bin/bash
# Build (signed), install, and launch PocketDJ on Levi's iPhone.
# Run this from a shell in the GUI (Aqua) login session — e.g. via Claude Code's `!` prefix
# or your own Terminal — because code-signing needs Aqua-session keychain access that a
# detached/Background-session process can't reach (errSecInternalComponent).
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."   # apple/
DEV=59C072A6-6201-5A10-AA86-4EE176FDC8A8

APP="build-device/Build/Products/Debug-iphoneos/PocketDJ.app"
# A failed build must never fall through to installing a STALE product from a
# previous run — that shipped an old binary to the phone once (the device went
# unavailable, xcodebuild died at destination resolution, and the [ -d ] check
# passed on yesterday's app). Remove the product first and gate on the build's
# own exit code, not the product's existence.
rm -rf "$APP"

echo "▸ Building (signed) for the device…"
set +o pipefail  # grep exiting 1 on a quiet log must not mask xcodebuild's status
xcodebuild -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination "platform=iOS,id=$DEV" -derivedDataPath build-device \
  -configuration Debug -allowProvisioningUpdates build \
  | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED|CodeSign failed"
BUILD_RC=${PIPESTATUS[0]}
set -o pipefail
[ "$BUILD_RC" -eq 0 ] || { echo "✗ xcodebuild exited $BUILD_RC — not installing"; exit "$BUILD_RC"; }
[ -d "$APP" ] || { echo "✗ no app product — build failed"; exit 1; }

echo "▸ Installing onto the iPhone…"
xcrun devicectl device install app --device "$DEV" "$APP"

echo "▸ Launching…"
xcrun devicectl device process launch --device "$DEV" com.levi.pocketdj

echo "✓ DONE — PocketDJ deployed to the iPhone"
