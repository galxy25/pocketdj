#!/usr/bin/env bash
# Build + upload per-song lyrics text files so the app can LAZY-LOAD lyrics on demand
# (the lean seed strips them). Served same-origin via CloudFront at /lyrics/<songId>.txt;
# the app fetches + caches a song's lyrics in IndexedDB only when its detail card opens.
#
#   scripts/lyrics-cdn.sh dev
#   scripts/lyrics-cdn.sh prod
#   SKIP_BUILD=1 scripts/lyrics-cdn.sh dev    # re-upload only (index-out/lyrics already built)
set -euo pipefail
ENV="${1:-dev}"; case "$ENV" in dev|prod) ;; *) echo "usage: scripts/lyrics-cdn.sh <dev|prod>"; exit 1 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
PROFILE="${AWS_PROFILE_OVERRIDE:-levi}"
ACCT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
BUCKET="pocketdj-${ENV}-web-${ACCT}"
INDEX="${INDEX:-index-out/current/index.json}"
OUT="${OUT:-index-out/lyrics}"

if [ "${SKIP_BUILD:-}" != "1" ]; then
  node .claude/skills/analog-indexer/lib/build-lyrics-cdn.mjs --index "$INDEX" --out "$OUT"
fi

COUNT="$(ls "$OUT" 2>/dev/null | wc -l | tr -d ' ')"
echo "▶ Syncing $COUNT lyrics files -> s3://$BUCKET/lyrics/ …"
# --delete prunes lyrics for songs that lost them (e.g. deduped away); scoped to /lyrics/.
aws s3 sync "$OUT" "s3://$BUCKET/lyrics/" --profile "$PROFILE" --delete \
  --content-type "text/plain; charset=utf-8" --cache-control "public,max-age=86400"

CF_ID=""
case "$ENV" in dev) CF_ID="${CF_ID_DEV:-E123GKAO9JVETP}" ;; prod) CF_ID="${CF_ID_PROD:-E1SP8M1SIF7Q8D}" ;; esac
if [ -n "$CF_ID" ]; then
  aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths "/lyrics/*" \
    --profile "$PROFILE" --query 'Invalidation.Id' --output text 2>/dev/null || true
fi
echo "✓ Lyrics CDN [$ENV]: s3://$BUCKET/lyrics/ ($COUNT files)"
