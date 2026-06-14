#!/usr/bin/env bash
# Mirror album art to our S3/CloudFront so covers are self-hosted + offline-durable.
#   1. thumbnail every remote cover to index-out/art/<albumId>.jpg + rewrite the index's
#      coverArtSources (lib/mirror-art.mjs)
#   2. sync the thumbnails to s3://<web-bucket>/art/ (served same-origin by the existing
#      CloudFront, so the app can fetch+thumbnail them into durable IndexedDB blobs)
#
#   scripts/mirror-art.sh dev          # thumbnail (resumable) + upload to dev
#   scripts/mirror-art.sh prod         # ... to prod
#   SKIP_THUMBS=1 scripts/mirror-art.sh dev   # re-upload only (art dir already built)
#   INDEX=index-out/current/index.json scripts/mirror-art.sh dev
set -euo pipefail

ENV="${1:-dev}"
case "$ENV" in dev|prod) ;; *) echo "usage: scripts/mirror-art.sh <dev|prod>"; exit 1 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
PROFILE="${AWS_PROFILE_OVERRIDE:-levi}"
ACCT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
BUCKET="pocketdj-${ENV}-web-${ACCT}"
INDEX="${INDEX:-index-out/current/index.json}"
ART_DIR="${ART_DIR:-index-out/art}"

if [ "${SKIP_THUMBS:-}" != "1" ]; then
  echo "▶ Thumbnailing covers + rewriting coverArtSources…"
  node .claude/skills/analog-indexer/lib/mirror-art.mjs \
    --index "$INDEX" --art-dir "$ART_DIR" --cdn-prefix /art \
    --concurrency "${MIRROR_CONC:-8}" --write-index
fi

COUNT="$(ls "$ART_DIR" 2>/dev/null | wc -l | tr -d ' ')"
echo "▶ Syncing $COUNT thumbnails -> s3://$BUCKET/art/ …"
aws s3 sync "$ART_DIR" "s3://$BUCKET/art/" --profile "$PROFILE" \
  --content-type image/jpeg --cache-control "public,max-age=31536000,immutable" --size-only

CF_ID=""
case "$ENV" in dev) CF_ID="${CF_ID_DEV:-E123GKAO9JVETP}" ;; prod) CF_ID="${CF_ID_PROD:-E1SP8M1SIF7Q8D}" ;; esac
if [ -n "$CF_ID" ]; then
  echo "▶ Invalidating CloudFront /art/* …"
  aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths "/art/*" \
    --profile "$PROFILE" --query 'Invalidation.Id' --output text 2>/dev/null || true
fi

echo "✓ Art mirrored to [$ENV]: s3://$BUCKET/art/ ($COUNT files)"
echo "  (next: rebuild the lean seed from $INDEX and deploy so the app picks up coverArtSources)"
