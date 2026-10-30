#!/usr/bin/env bash
# Regenerate the REAL iOS-exported Android test fixtures (ANS-SVC-2).
# Runs the opt-in FixtureExportTests on the iOS Simulator; the test builds a synthetic store and
# writes backup.pocketdj.zip / pocket.pdjcollection / playlist.pdjcollection via the real exporters.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$REPO/android/app/src/test/resources/backup/ios-real}"
SIM="${PDJ_SIM_ID:-3FE7AC66-C9C2-4495-9AC4-0DC7CE5E3DAD}"
mkdir -p "$OUT"
cd "$HERE/.."
trap 'rm -rf "$HERE/../build"' EXIT
# Clear stale fixtures so a silent XCTSkip (xcodebuild exits 0) cannot pass as a fresh export.
rm -f "$OUT/backup.pocketdj.zip" "$OUT/pocket.pdjcollection" "$OUT/playlist.pdjcollection"
xcodegen generate
# xcodebuild forwards TEST_RUNNER_* env vars into the test process (prefix stripped).
TEST_RUNNER_PDJ_FIXTURE_OUT="$OUT" xcodebuild test \
  -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination "id=$SIM" -derivedDataPath build \
  -only-testing:PocketDJTests/FixtureExportTests \
  CODE_SIGNING_ALLOWED=NO
for f in backup.pocketdj.zip pocket.pdjcollection playlist.pdjcollection; do
  [ -s "$OUT/$f" ] || { echo "ERROR: $f was not regenerated (test skipped? PDJ_FIXTURE_OUT not forwarded?)" >&2; exit 1; }
done
ls -l "$OUT"
shasum -a 256 "$OUT"/*.zip "$OUT"/*.pdjcollection
