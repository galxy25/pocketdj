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
python3 -c 'import json,sys; [json.load(open(f)) for f in sys.argv[1:]]' "$SRC/assetlinks.json" "$SRC/apple-app-site-association"
for f in assetlinks.json apple-app-site-association; do
  aws s3 cp "$SRC/$f" "s3://$PDJ_DEV_WEB_BUCKET/jukebox/.well-known/$f" \
    --profile "$PDJ_PROFILE" --content-type application/json --cache-control "max-age=300" --only-show-errors
done
aws cloudfront create-invalidation --distribution-id "$PDJ_CF_JUKEBOX" \
  --paths '/.well-known/assetlinks.json' '/.well-known/apple-app-site-association' --profile "$PDJ_PROFILE"
for f in assetlinks.json apple-app-site-association; do
  curl -sS -o /dev/null -w "$f -> %{http_code} %{content_type} redirects=%{num_redirects}\n" \
    "https://jukebox.pocket-dj.com/.well-known/$f"
done
