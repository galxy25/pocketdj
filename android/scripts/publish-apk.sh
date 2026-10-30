#!/usr/bin/env bash
# Publish a sideload APK to pocket-dj.com/android/ (release plan Phase B). GREEN only.
#
#   android/scripts/publish-apk.sh [RELEASE_OUT_DIR] [--notes "text"] [--dry-run]
#
# RELEASE_OUT_DIR is the output folder of android/scripts/release-aab.sh (default
# android/build/release-out). It must hold exactly one PocketDJ-<ver>-<code>.apk (the newest is
# taken if there are several) and the SHA256SUMS that release-aab.sh wrote next to it.
#
# Uploads, in this order (latest.json LAST so nothing points at a file that isn't there yet):
#   /android/PocketDJ-<ver>-<code>.apk          immutable, Content-Disposition attachment
#   /android/PocketDJ-<ver>-<code>.apk.sha256   sha256sum format
#   /android/PocketDJ.apk                        server-side copy, max-age=300 (stable "latest" URL)
#   /android/latest.json                         max-age=60, read by the website (and later the updater)
# then invalidates the two mutable paths on the www CloudFront distribution, and keeps the newest
# $KEEP (default 4) versioned APKs, pruning older ones.
#
# Env: POCKETDJ_ENV must be green (default). PLAY_URL: set once the Play listing is live to put it
# in latest.json ("play"); the website's own badge state is the data-play flag in www/index.html.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$REPO/android/build/release-out"
NOTES=""
DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) OUT_DIR="$1"; shift ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "${POCKETDJ_ENV:-green}" == green ]] || die "the website lives in GREEN only (POCKETDJ_ENV=${POCKETDJ_ENV})"
POCKETDJ_ENV=green source "$REPO/scripts/lib/aws-env.sh"
[[ "$PDJ_WWW_BUCKET" == pocketdj-www-623170744161 && "$PDJ_CF_WWW" == ELX7JB4JIT29F ]] \
  || die "unexpected www target $PDJ_WWW_BUCKET / $PDJ_CF_WWW"

SITE="https://pocket-dj.com"
KEEP="${KEEP:-4}"
MIN_SDK=35
# Pinned app-signing certificate (same as release-aab.sh). Play re-signs with this key too.
APPSIGN_SHA256="26c3cd8f7f56a28bf0f6e9479a05a97a7216bd5d768109e6805e0650dc4cd674"

APK="$(ls -t "$OUT_DIR"/PocketDJ-*-*.apk 2>/dev/null | head -1 || true)"
[[ -n "$APK" ]] || die "no PocketDJ-<ver>-<code>.apk in $OUT_DIR (run android/scripts/release-aab.sh first)"
FILE="$(basename "$APK")"
[[ "$FILE" =~ ^PocketDJ-([0-9][0-9.]*)-([0-9]+)\.apk$ ]] || die "unexpected APK name $FILE"
VNAME="${BASH_REMATCH[1]}"; VCODE="${BASH_REMATCH[2]}"

SHA="$(shasum -a 256 "$APK" | cut -d' ' -f1)"
if [[ -f "$OUT_DIR/SHA256SUMS" ]]; then
  grep -q "^$SHA  $FILE\$" "$OUT_DIR/SHA256SUMS" || die "$FILE does not match SHA256SUMS"
else
  echo "WARN: no SHA256SUMS in $OUT_DIR; using the computed digest" >&2
fi
BYTES="$(stat -f %z "$APK" 2>/dev/null || stat -c %s "$APK")"

# Re-check the signer: never publish an APK Play would refuse to update over.
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$(ls -d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)"
if [[ -x "$BT/apksigner" ]]; then
  # Capture first: `cmd | grep -q` under pipefail dies of SIGPIPE (exit 141).
  certs="$("$BT/apksigner" verify --print-certs "$APK")"
  grep -qi "SHA-256 digest: $APPSIGN_SHA256" <<<"$certs" \
    || die "$FILE is not signed with the pinned app-signing certificate"
  badging="$("$BT/aapt2" dump badging "$APK")"; badging="${badging%%$'\n'*}"
  [[ "$badging" == *"name='com.levi.pocketdj'"* && "$badging" == *"versionCode='$VCODE'"* ]] \
    || die "badging mismatch: $badging"
else
  die "apksigner not found under $ANDROID_HOME/build-tools"
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
printf '%s  %s\n' "$SHA" "$FILE" > "$WORK/$FILE.sha256"
PLAY_JSON=null
[[ -n "${PLAY_URL:-}" ]] && PLAY_JSON="\"$PLAY_URL\""
NOTES_JSON="$(printf '%s' "$NOTES" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
cat > "$WORK/latest.json" <<JSON
{
  "versionName": "$VNAME",
  "versionCode": $VCODE,
  "url": "$SITE/android/$FILE",
  "latestUrl": "$SITE/android/PocketDJ.apk",
  "sha256": "$SHA",
  "size": $BYTES,
  "minSdk": $MIN_SDK,
  "abi": "arm64-v8a",
  "certSha256": "$APPSIGN_SHA256",
  "minSupportedVersionCode": 0,
  "released": "$(date -u +%Y-%m-%d)",
  "notes": $NOTES_JSON,
  "play": $PLAY_JSON
}
JSON
python3 -m json.tool "$WORK/latest.json" > /dev/null || die "latest.json is not valid JSON"
cat "$WORK/latest.json"

B="s3://$PDJ_WWW_BUCKET/android"
AWS=(aws --profile "$PDJ_PROFILE" --region "$PDJ_REGION")
run() { if [[ $DRY == 1 ]]; then echo "DRY: $*"; else "$@"; fi; }
APK_TYPE=application/vnd.android.package-archive

echo "==> upload $FILE ($BYTES bytes) to $B/"
run "${AWS[@]}" s3 cp "$APK" "$B/$FILE" --content-type "$APK_TYPE" \
  --cache-control 'public, max-age=31536000, immutable' \
  --content-disposition "attachment; filename=\"PocketDJ-$VNAME.apk\""
run "${AWS[@]}" s3 cp "$WORK/$FILE.sha256" "$B/$FILE.sha256" \
  --content-type 'text/plain; charset=utf-8' --cache-control 'public, max-age=31536000, immutable'
echo "==> stable copy PocketDJ.apk"
run "${AWS[@]}" s3 cp "$B/$FILE" "$B/PocketDJ.apk" --metadata-directive REPLACE \
  --content-type "$APK_TYPE" --cache-control 'public, max-age=300' \
  --content-disposition "attachment; filename=\"PocketDJ-$VNAME.apk\""
echo "==> latest.json (last)"
run "${AWS[@]}" s3 cp "$WORK/latest.json" "$B/latest.json" \
  --content-type 'application/json' --cache-control 'public, max-age=60'
run "${AWS[@]}" cloudfront create-invalidation --distribution-id "$PDJ_CF_WWW" \
  --paths /android/PocketDJ.apk /android/latest.json --query 'Invalidation.Id' --output text

echo "==> prune: keep newest $KEEP versioned APKs"
# Sort by versionCode (3rd dash field), newest first; everything after the first $KEEP goes.
"${AWS[@]}" s3 ls "$B/" | awk '{print $4}' | grep -E '^PocketDJ-[0-9.]+-[0-9]+\.apk$' \
  | sort -t- -k3,3nr | awk -v k="$KEEP" 'NR>k' > "$WORK/prune.txt" || true
while IFS= read -r o; do
  [[ -z "$o" || "$o" == "$FILE" ]] && continue
  run "${AWS[@]}" s3 rm "$B/$o"
  run "${AWS[@]}" s3 rm "$B/$o.sha256"
done < "$WORK/prune.txt"

if [[ $DRY == 0 ]]; then
  echo "==> verify"
  curl -sI "$SITE/android/$FILE" | grep -iE '^(HTTP|content-type|content-length|content-disposition)'
  got="$(curl -s "$SITE/android/$FILE" | shasum -a 256 | cut -d' ' -f1)"
  [[ "$got" == "$SHA" ]] || die "served APK digest $got != $SHA"
fi
echo "==> Done $VNAME ($VCODE) $SITE/android/PocketDJ.apk"
