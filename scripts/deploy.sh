#!/usr/bin/env bash
# Deploy the PocketDJ PWA to an S3 static-website bucket (dev or prod).
#
#   scripts/deploy.sh dev      # -> pocketdj-dev-<acct>
#   scripts/deploy.sh prod     # -> pocketdj-prod-<acct>
#   SKIP_BUILD=1 scripts/deploy.sh dev   # reuse existing dist/
#   CONFIG_ONLY=1 PDJ_ENDPOINTS_ENV=green scripts/deploy.sh prod   # flip the backend ONLY
#
# REMOTE ENDPOINT CONFIG (docs/design/remote-endpoints.md): every deploy also publishes
# config/endpoints.${PDJ_ENDPOINTS_ENV:-blue}.json to s3://<bucket>/config/endpoints.json
# (short TTL) — on prod that is https://app.pocket-dj.com/config/endpoints.json, the stable
# URL every native client fetches at launch. It is validated with the clients' own rules
# first (scripts/validate-endpoints.ts); a doc the clients would reject is never published.
# CONFIG_ONLY=1 skips the build + site sync and publishes just that doc (+ invalidation).
#
# Uses AWS profile "levi" (blue; POCKETDJ_ENV=green -> "llc", see scripts/lib/aws-env.mjs). Buckets are public static-website hosts with the SPA
# error-document = index.html. Cache strategy is the important bit:
#   - hashed assets/*  -> immutable, 1-year cache
#   - index.html, sw.js, registerSW.js, manifest.webmanifest -> no-cache
#     so the auto-updating service worker always picks up a new deploy.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/aws-env.sh"

ENV="${1:-}"
case "$ENV" in
  dev|prod) ;;
  *) echo "usage: scripts/deploy.sh <dev|prod>"; exit 1 ;;
esac

PROFILE="${AWS_PROFILE_OVERRIDE:-$PDJ_PROFILE}"
REGION="${AWS_REGION_OVERRIDE:-$PDJ_REGION}"
ACCT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
BUCKET="pocketdj-${ENV}-web-${ACCT}"
ENDPOINT="http://${BUCKET}.s3-website-${REGION}.amazonaws.com"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Which backend the clients should use (blue = 011183829623, green = 623170744161). The
# committed config/endpoints.<env>.json is the source of truth; default blue.
ENDPOINTS_ENV="${PDJ_ENDPOINTS_ENV:-blue}"
ENDPOINTS_FILE="config/endpoints.${ENDPOINTS_ENV}.json"
[ -f "$ENDPOINTS_FILE" ] || { echo "✗ no $ENDPOINTS_FILE (PDJ_ENDPOINTS_ENV=$ENDPOINTS_ENV)"; exit 1; }
echo "▶ Validating $ENDPOINTS_FILE…"
npx --yes tsx scripts/validate-endpoints.ts "$ENDPOINTS_FILE"

# Clients revalidate after 5 min at most (browser/URLSession/OkHttp honor max-age); the
# CloudFront invalidation below clears the edge immediately.
ENDPOINTS_CACHE="public,max-age=300"
publish_endpoints() {
  aws s3 cp "$ENDPOINTS_FILE" "s3://$BUCKET/config/endpoints.json" --profile "$PROFILE" \
    --content-type "application/json" --cache-control "$ENDPOINTS_CACHE" --only-show-errors
  echo "✓ Published $ENDPOINTS_FILE -> s3://$BUCKET/config/endpoints.json"
}

echo "▶ Deploying PocketDJ [$ENV] -> s3://$BUCKET ($REGION)"

if [ "${CONFIG_ONLY:-}" = "1" ]; then
  publish_endpoints
  case "$ENV" in
    dev)  CF_ONLY_ID="${CF_ID_DEV:-E123GKAO9JVETP}" ;;
    prod) CF_ONLY_ID="${CF_ID_PROD:-E1SP8M1SIF7Q8D}" ;;
  esac
  INV=$(aws cloudfront create-invalidation --distribution-id "$CF_ONLY_ID" --paths "/config/*" \
    --profile "$PROFILE" --query 'Invalidation.Id' --output text 2>/dev/null || true)
  echo "✓ CONFIG_ONLY [$ENV]: endpoints env=$ENDPOINTS_ENV (invalidation ${INV:-none})"
  exit 0
fi

if [ "${SKIP_BUILD:-}" != "1" ]; then
  # Ensure demo data exists so the live "Load demo data" button works.
  [ -f public/mock-index.json ] || npm run gen:mock --silent -- --albums 280 --out public/mock-index.json
  # Regenerate the recommendation-engine feature file from the CURRENT catalog indexes so the
  # rec Lambda never scores against a stale committed snapshot (the indexes churn nightly:
  # am-sync 04:00, digital-sync 05:00, streaming-links 06:00 — which also regens + publishes
  # this file on its own). Soft-fail: a regen bug must not block a catalog/PWA ship; the
  # previous rec-features.json keeps serving.
  echo "▶ Regenerating rec-features.json…"
  node scripts/build-rec-features.mjs \
    || echo "⚠ rec-features regeneration failed — deploying the previous rec-features.json"
  echo "▶ Building…"
  npm run build --silent
fi
[ -d dist ] || { echo "no dist/ — run a build first"; exit 1; }

# index.html + SW must be no-cache so the auto-updating SW always sees a fresh deploy.
# current-index.json (the auto-seed catalog) is also no-cache so catalog updates and the
# Settings "re-pull seed" actually fetch fresh data instead of a stale immutable copy.
# apple-music-index.json is likewise no-cache: it's refreshed incrementally by the
# catalog-id resolver crawl (scripts/resolve-apple-music-catalog.mjs), and the native
# app fetches it at runtime from CloudFront — immutable caching would pin clients to a
# stale, under-resolved copy for a year.
# rec-features.json: regenerated every deploy (above) + nightly; the rec-engine Lambda
# refetches it with If-None-Match on a 15-min TTL, so it must revalidate, never pin.
# search-config.json: the swappable aoss host (a collection rebuild / account move rewrites
# it) — immutable caching would pin clients to a dead host for a year.
NOCACHE=(index.html sw.js registerSW.js manifest.webmanifest current-index.json apple-music-index.json rec-features.json search-config.json)
EXCL=()
for f in "${NOCACHE[@]}"; do EXCL+=(--exclude "$f"); done

echo "▶ Syncing immutable assets…"
# IMPORTANT: --delete prunes anything in the bucket not in dist/. The album-art mirror
# (scripts/mirror-art.sh -> art/), the lyrics CDN (scripts/lyrics-cdn.sh -> lyrics/), and the
# live Jukebox Hero pages (scripts/jukebox-server.mjs -> jukebox/) upload to the SAME bucket but
# are NOT part of dist/ — exclude them so a deploy never wipes those caches / kills live jukeboxes.
# config/ (the remote endpoint doc) is published separately below — excluded so --delete never
# opens a window where clients fetch a 404/SPA page instead of the doc.
aws s3 sync dist/ "s3://$BUCKET" --profile "$PROFILE" --delete --exclude "art/*" --exclude "lyrics/*" --exclude "jukebox/*" --exclude "config/*" \
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

publish_endpoints

echo "✓ Deployed [$ENV]: $ENDPOINT (endpoints env=$ENDPOINTS_ENV)"

# If a CloudFront distribution fronts this env (for HTTPS/PWA), invalidate it so the new
# index.html + hashed assets propagate together (avoids serving a stale shell that points
# at just-deleted asset hashes). Distribution ids per env:
CF_ID=""
case "$ENV" in
  dev)  CF_ID="${CF_ID_DEV:-$PDJ_CF_DEV}" ;;
  prod) CF_ID="${CF_ID_PROD:-$PDJ_CF_PROD}" ;;
esac
if [ -n "$CF_ID" ]; then
  INV=$(aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths "/*" \
    --profile "$PROFILE" --query 'Invalidation.Id' --output text 2>/dev/null || true)
  DOMAIN=$(aws cloudfront get-distribution --id "$CF_ID" --profile "$PROFILE" \
    --query 'Distribution.DomainName' --output text 2>/dev/null || true)
  [ -n "$DOMAIN" ] && echo "✓ CloudFront [$ENV]: https://$DOMAIN (invalidation $INV)"
fi
