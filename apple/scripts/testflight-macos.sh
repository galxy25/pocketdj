#!/usr/bin/env bash
#
# testflight-macos.sh — archive PocketDJ (native macOS) and upload to TestFlight.
#
# Sibling of testflight.sh (iOS). Same local-archive + ASC-API-key flow, but builds the
# NATIVE macOS app (a sandboxed Mac App Store build — NOT the "iPhone/iPad app on Mac"
# variant). The macOS App Sandbox entitlements come from PocketDJ/PocketDJ-macOS.entitlements,
# wired for the macOS SDK via CODE_SIGN_ENTITLEMENTS[sdk=macosx*] in project.yml.
#
# The app's macOS platform in App Store Connect is created automatically on the first
# successful macOS upload (the iOS app record already exists under com.levi.pocketdj).
#
# CONFIG (same as testflight.sh):
#   ASC_KEY_ID     — App Store Connect API Key ID (Admin role)
#   ASC_ISSUER_ID  — Issuer ID
#   ASC_KEY_PATH   — path to AuthKey_${ASC_KEY_ID}.p8
#                    (default: ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8)
#
# USAGE:
#   apple/scripts/testflight-macos.sh            # build number = current unix timestamp
#   BUILD_NUMBER=42 apple/scripts/testflight-macos.sh
#
set -euo pipefail

# --- resolve paths -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APPLE_DIR"

TEAM_ID="EC27UF79GL"
SCHEME="PocketDJ"
ARCHIVE="build-release/PocketDJ-macOS.xcarchive"
EXPORT_DIR="build-release/export-macos"
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

echo "==> Archiving $SCHEME for macOS (build $BUILD_NUMBER)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
# Cloud signing via the ASC key: -allowProvisioningUpdates mints the Apple Distribution
# cert + Mac App Store provisioning profile (the key must be Admin role), so no Apple ID
# needs to be signed into Xcode (headless/CI).
xcodebuild \
  -project PocketDJ.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -allowProvisioningUpdates \
  clean archive

echo "==> Writing ExportOptions.plist (app-store-connect, upload)"
EXPORT_PLIST="$(mktemp -t PocketDJMacExportOptions).plist"
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

echo "==> Exporting + uploading to TestFlight (macOS)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -allowProvisioningUpdates

echo "==> Done. macOS build $BUILD_NUMBER uploaded; it'll appear under the app's macOS"
echo "    platform in TestFlight after Apple finishes processing (~5-15 min)."
