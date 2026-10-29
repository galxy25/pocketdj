#!/usr/bin/env bash
# Publish legal-site/ to https://legal.pocket-dj.com (GREEN only: bucket PDJ_LEGAL_BUCKET,
# CloudFront PDJ_CF_LEGAL). Rebuilds the generated pages first.
#
#   scripts/legal-site-deploy.sh            # build + sync + invalidate
#   scripts/legal-site-deploy.sh --dry-run  # show what would change
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POCKETDJ_ENV=green source "$ROOT/scripts/lib/aws-env.sh"
[ "$PDJ_ENV" = green ] || { echo "refusing: PDJ_ENV=$PDJ_ENV (legal site deploys to green only)" >&2; exit 1; }
PROFILE="${AWS_PROFILE:-$PDJ_PROFILE}"
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY="--dryrun"

node "$ROOT/scripts/legal-site-build.mjs"
if grep -rlE '\{\{|\[Publisher\]|#TOUPDATE' "$ROOT/legal-site" --include='*.html' | grep -v '_template.html'; then
  echo "refusing: placeholder or marker found in the files above" >&2; exit 1
fi

aws s3 sync "$ROOT/legal-site" "s3://$PDJ_LEGAL_BUCKET" --profile "$PROFILE" $DRY \
  --exclude 'README.md' --exclude '_*' --exclude '.*' \
  --content-type 'text/html; charset=utf-8' --cache-control 'public, max-age=300'
[ -n "$DRY" ] && exit 0
aws cloudfront create-invalidation --profile "$PROFILE" --distribution-id "$PDJ_CF_LEGAL" --paths '/*' \
  --query 'Invalidation.{id:Id,status:Status}' --output text
