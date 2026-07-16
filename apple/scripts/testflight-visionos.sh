#!/usr/bin/env bash
#
# testflight-visionos.sh — archive PocketDJ (visionOS) and upload the build to TestFlight.
#
# Sibling of testflight.sh (iOS) and testflight-macos.sh (macOS): same local-archive +
# cloud-signing flow, but archives the NATIVE visionOS slice (device family 7). visionOS is
# a SEPARATE platform in App Store Connect, so the iOS build (testflight.sh) does NOT put a
# build on the Vision Pro — you need THIS to TestFlight-test anything visionOS-specific.
#
# Unlike the macOS script, this uses CLOUD signing via the App Store Connect API key (same as
# iOS), so it runs headless — no login-keychain unlock needed. If the archive ever dies with
# `errSecInternalComponent` / "No profiles for com.levi.pocketdj", do the one-time Xcode.app
# archive bootstrap described in the apple-publish skill (mints the Apple Distribution cert +
# grants CLI key access), then this runs headless for every future build.
#
# CONFIG (same as testflight.sh):
#   ASC_KEY_ID     — App Store Connect API Key ID (Admin role)
#   ASC_ISSUER_ID  — Issuer ID
#   ASC_KEY_PATH   — path to AuthKey_XXXXX.p8
#                    (default: ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8)
#
# USAGE:
#   apple/scripts/testflight-visionos.sh              # build number = current unix timestamp
#   BUILD_NUMBER=42 apple/scripts/testflight-visionos.sh
#
set -euo pipefail

# Load ASC credentials from the durable config unless already exported.
# ~/.config/pocketdj/asc.env holds ASC_KEY_ID (Admin role) + ASC_ISSUER_ID.
if [ -z "${ASC_KEY_ID:-}" ] && [ -f "$HOME/.config/pocketdj/asc.env" ]; then
  . "$HOME/.config/pocketdj/asc.env"
fi

# Unlock the dedicated CI signing keychain (headless codesign). The login
# keychain's keys are ACL'd to require GUI prompts, which fails with
# errSecInternalComponent in headless sessions; pocketdj-ci holds an
# "Apple Development: Created via API" identity with a non-interactive ACL.
if [ -f "$HOME/.config/pocketdj/ci-keychain-pass" ]; then
  security unlock-keychain -p "$(cat "$HOME/.config/pocketdj/ci-keychain-pass")" pocketdj-ci.keychain-db 2>/dev/null || true
fi

# --- resolve paths -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APPLE_DIR"

TEAM_ID="EC27UF79GL"
SCHEME="PocketDJ"
# Separate archive/export paths from the iOS script so the two never clobber each other.
ARCHIVE="build-release-visionos/PocketDJ.xcarchive"
EXPORT_DIR="build-release-visionos/export"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"   # monotonic; App Store Connect rejects dupes
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-UNSET}.p8}"

# --- preflight ---------------------------------------------------------------
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "ERROR: xcodebuild not pointing at Xcode. Run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi
: "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect API Key ID)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect Issuer ID)}"
[ -f "$ASC_KEY_PATH" ] || { echo "ERROR: API key not found at $ASC_KEY_PATH" >&2; exit 1; }

echo "==> Regenerating project from project.yml"
xcodegen generate

echo "==> Archiving $SCHEME for visionOS (build $BUILD_NUMBER)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
# Cloud signing via the API key on the ARCHIVE step (see testflight.sh for the rationale).
xcodebuild \
  -project PocketDJ.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=visionOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -allowProvisioningUpdates \
  clean archive

echo "==> Writing ExportOptions.plist (app-store-connect, upload)"
EXPORT_PLIST="$(mktemp -t PocketDJExportOptions).plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "==> Exporting + uploading to TestFlight"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -allowProvisioningUpdates

echo "==> Done. Build $BUILD_NUMBER uploaded (visionOS); it'll appear in TestFlight after Apple finishes processing (~5-15 min)."
