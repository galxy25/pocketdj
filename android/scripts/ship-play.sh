#!/usr/bin/env bash
# The ONE command for a Google Play release: build + verify, then publish the identical build as
# the sideload APK on pocket-dj.com, so the website never lags Play.
#
#   android/scripts/ship-play.sh [--notes "release notes"] [OUT_DIR]
#
# 1. release-aab.sh       -> signed AAB (upload to Play Console) + universal APK + SHA256SUMS
# 2. publish-apk.sh       -> pocket-dj.com/android/{PocketDJ-<ver>-<code>.apk,PocketDJ.apk,latest.json}
# Then upload the printed .aab in Play Console. Publishing first is deliberate: the APK is the same
# signed build Play will serve, so sideloaders get it immediately and Play users after review.
# GREEN only (publish-apk.sh enforces it). Set PLAY_URL once the Play listing is live.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR=""
NOTES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) OUT_DIR="$1"; shift ;;
  esac
done
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/../build/release-out}"

"$SCRIPT_DIR/release-aab.sh" "$OUT_DIR"
if [[ -n "$NOTES" ]]; then
  POCKETDJ_ENV=green "$SCRIPT_DIR/publish-apk.sh" "$OUT_DIR" --notes "$NOTES"
else
  POCKETDJ_ENV=green "$SCRIPT_DIR/publish-apk.sh" "$OUT_DIR"
fi

AAB="$(ls -t "$OUT_DIR"/PocketDJ-*-*.aab | head -1)"
echo "==> Website updated: $(curl -s https://pocket-dj.com/android/latest.json | tr -d '\n' | head -c 160)"
echo "==> Upload to Play Console: $AAB"
echo "==> Shipped"
