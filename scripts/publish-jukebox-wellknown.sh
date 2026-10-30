#!/usr/bin/env bash
# Publish the jukebox domain's .well-known files (iOS Universal Links AASA + Android assetlinks.json)
# to S3 and invalidate CloudFront. Env: POCKETDJ_ENV=green (default) | blue.
# Refuses to upload while assetlinks.json still holds REPLACE_WITH_* fingerprints
# (ALLOW_PLACEHOLDERS=1 overrides; Android would then ignore the whole statement).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/aws-env.sh
SRC=scripts/jukebox-site/.well-known
if grep -q REPLACE_WITH_ "$SRC/assetlinks.json" && [ "${ALLOW_PLACEHOLDERS:-0}" != "1" ]; then
  echo "assetlinks.json still has REPLACE_WITH_* fingerprints; fill in the release + Play App Signing SHA-256 first." >&2
  exit 1
fi
AASA=scripts/jukebox-site/apple-app-site-association # single source of truth (README Step 2 uses it too)
python3 -c 'import json,sys; [json.load(open(f)) for f in sys.argv[1:]]' "$SRC/assetlinks.json" "$AASA"
for f in assetlinks.json apple-app-site-association; do
  src="$SRC/$f"; [ "$f" = apple-app-site-association ] && src="$AASA"
  aws s3 cp "$src" "s3://$PDJ_DEV_WEB_BUCKET/jukebox/.well-known/$f" \
    --profile "$PDJ_PROFILE" --content-type application/json --cache-control "max-age=300" --only-show-errors
done
INV=$(aws cloudfront create-invalidation --distribution-id "$PDJ_CF_JUKEBOX" \
  --paths '/.well-known/assetlinks.json' '/.well-known/apple-app-site-association' --profile "$PDJ_PROFILE" \
  --query Invalidation.Id --output text)
aws cloudfront wait invalidation-completed --distribution-id "$PDJ_CF_JUKEBOX" --id "$INV" --profile "$PDJ_PROFILE"
fail=0
for f in assetlinks.json apple-app-site-association; do
  out=$(curl -sS -o /dev/null -H 'Cache-Control: no-cache' \
    -w "%{http_code} %{content_type} %{num_redirects}" "https://jukebox.pocket-dj.com/.well-known/$f")
  echo "$f -> $out"
  set -- $out
  if [ "$1" != 200 ] || [[ "$2" != application/json* ]] || [ "$3" != 0 ]; then
    echo "FAIL: $f must be 200 application/json with no redirect" >&2; fail=1
  fi
done
exit $fail
