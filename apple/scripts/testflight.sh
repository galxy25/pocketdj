#!/usr/bin/env bash
#
# testflight.sh — archive PocketDJ (iOS) and upload the build to TestFlight.
#
# This is the LOCAL-ARCHIVE path (no Xcode Cloud): build on this Mac, then push the
# .ipa straight to App Store Connect via the App Store Connect API key. Avoids the
# "Grant Access to Your Source Code" dialog entirely — nothing here clones the remote
# repo or the public ZIPFoundation package over the network beyond normal SPM resolve.
#
# ONE-TIME SETUP (browser, see docs):
#   1. App Store Connect → Apps → New App, bundle id com.levi.pocketdj.
#   2. App Store Connect → Users and Access → Integrations → App Store Connect API:
#      create a key (App Manager role), download AuthKey_XXXXX.p8 ONCE, note Key ID + Issuer ID.
#   3. developer.apple.com → Identifiers → com.levi.pocketdj → MusicKit App Service enabled.
#
# CONFIG — set these once (e.g. in ~/.config/fish/config.fish or export before running):
#   ASC_KEY_ID     — the App Store Connect API Key ID
#   ASC_ISSUER_ID  — the Issuer ID (same page as the key)
#   ASC_KEY_PATH   — path to the downloaded AuthKey_XXXXX.p8
#                    (default: ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8)
#
# USAGE:
#   apple/scripts/testflight.sh            # build number = current unix timestamp
#   BUILD_NUMBER=42 apple/scripts/testflight.sh
#
set -euo pipefail

# --- resolve paths -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APPLE_DIR"

TEAM_ID="EC27UF79GL"
SCHEME="PocketDJ"
ARCHIVE="build-release/PocketDJ.xcarchive"
EXPORT_DIR="build-release/export"
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

echo "==> Archiving $SCHEME for iOS (build $BUILD_NUMBER)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
# Pass the App Store Connect API key to the ARCHIVE step too (not just export): with it,
# `-allowProvisioningUpdates` does CLOUD signing — minting the Apple Distribution cert + App
# Store profile via the key — so no Apple ID needs to be signed into Xcode (headless/CI). The
# key MUST be Admin role (App Manager fails: "No profiles for com.levi.pocketdj"). Without
# this, archive looks for an Xcode account and dies with "missing Xcode-Username".
xcodebuild \
  -project PocketDJ.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
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

echo "==> Done. Build $BUILD_NUMBER uploaded; it'll appear in TestFlight after Apple finishes processing (~5-15 min)."
