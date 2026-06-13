#!/usr/bin/env bash
# Deploy the PocketDJ PWA to an S3 static-website bucket (dev or prod).
#
#   scripts/deploy.sh dev      # -> pocketdj-dev-<acct>
#   scripts/deploy.sh prod     # -> pocketdj-prod-<acct>
#   SKIP_BUILD=1 scripts/deploy.sh dev   # reuse existing dist/
#
# Uses AWS profile "levi". Buckets are public static-website hosts with the SPA
# error-document = index.html. Cache strategy is the important bit:
#   - hashed assets/*  -> immutable, 1-year cache
#   - index.html, sw.js, registerSW.js, manifest.webmanifest -> no-cache
#     so the auto-updating service worker always picks up a new deploy.
set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  dev|prod) ;;
  *) echo "usage: scripts/deploy.sh <dev|prod>"; exit 1 ;;
esac

PROFILE="${AWS_PROFILE_OVERRIDE:-levi}"
REGION="${AWS_REGION_OVERRIDE:-us-west-2}"
ACCT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
BUCKET="pocketdj-${ENV}-web-${ACCT}"
ENDPOINT="http://${BUCKET}.s3-website-${REGION}.amazonaws.com"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶ Deploying PocketDJ [$ENV] -> s3://$BUCKET ($REGION)"

if [ "${SKIP_BUILD:-}" != "1" ]; then
  # Ensure demo data exists so the live "Load demo data" button works.
  [ -f public/mock-index.json ] || npm run gen:mock --silent -- --albums 280 --out public/mock-index.json
  echo "▶ Building…"
  npm run build --silent
fi
[ -d dist ] || { echo "no dist/ — run a build first"; exit 1; }

NOCACHE=(index.html sw.js registerSW.js manifest.webmanifest)
EXCL=()
for f in "${NOCACHE[@]}"; do EXCL+=(--exclude "$f"); done

echo "▶ Syncing immutable assets…"
aws s3 sync dist/ "s3://$BUCKET" --profile "$PROFILE" --delete \
  --cache-control "public,max-age=31536000,immutable" "${EXCL[@]}"

echo "▶ Syncing no-cache shell + service worker…"
INCL=()
for f in "${NOCACHE[@]}"; do INCL+=(--include "$f"); done
aws s3 sync dist/ "s3://$BUCKET" --profile "$PROFILE" \
  --cache-control "no-cache" --exclude "*" "${INCL[@]}"

# webmanifest needs the right content-type for installability
aws s3 cp "s3://$BUCKET/manifest.webmanifest" "s3://$BUCKET/manifest.webmanifest" \
  --profile "$PROFILE" --content-type "application/manifest+json" \
  --cache-control "no-cache" --metadata-directive REPLACE >/dev/null 2>&1 || true

echo "✓ Deployed [$ENV]: $ENDPOINT"
