#!/usr/bin/env bash
# Deploy the PocketDJ RECOMMENDATION-ENGINE Lambda behind an API Gateway HTTP API (WS-E).
# Cloned from scripts/lambda/am-playlist-sync/deploy.sh, minus all Secrets Manager steps —
# this endpoint holds no Apple credentials; auth is the per-profile TOFU bearer key the app
# mints (see index.mjs header).
#
# ENROLLMENT SECRET (REC_ENROLL_SECRET): creating a NEW profile's state object requires this
# shared secret in `x-pocketdj-enroll`; without it POST /events was an open write into a bucket
# with no lifecycle expiry. The app ships the same value in `Config.recEngineEnrollSecret`, so
# it is a capability token, not a per-user credential (see the index.mjs header for the
# multi-user revisit). This script PRESERVES the deployed value across re-runs — changing it
# de-facto rotates the token and every client build carrying the old one can no longer enroll,
# so rotate deliberately: export REC_ENROLL_SECRET=<new> before running, then ship a build with
# the new constant. If neither the env var nor a deployed value exists, one is minted and
# printed for pasting into Config.swift.
#
# Key recovery (single-user pragmatics): a genuinely wedged key — a reinstall without iCloud, or
# two devices enabling before CloudKit synced the rec-key doc — is fixed IN-APP now: "Delete
# cloud data" presents the enrollment secret, which DELETE /state accepts in place of the bound
# key, and the next upload re-binds fresh. The blunt instruments still exist: REC_ALLOW_REBIND=1
# on the function's env (dev only) or deleting rec/state/<hash>.json from the bucket by hand.
#
# Idempotent-ish; safe to re-run to update code.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-levi}"
REGION="us-west-2"; ACCT="011183829623"
FN="pocketdj-rec-engine"; ROLE="pocketdj-rec-engine-role"; API_NAME="pocketdj-rec-engine"
# Private state bucket: ONE JSON object per profile under rec/state/.
REC_BUCKET="pocketdj-rec-${ACCT}"
FEATURES_URL="https://d2p4cubg6se03u.cloudfront.net/rec-features.json"
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCT}:function:${FN}"
SELF="$(cd "$(dirname "$0")" && pwd)"
say(){ echo "[deploy-rec-engine] $*"; }

# 1) private state bucket. Block ALL public access. NO lifecycle expiry — this is the one
#    deliberate divergence from the am-sync jobs bucket: the rec state is durable per-profile
#    data (plays/favorites/collections), not a transient job artifact, and must persist until
#    the user's explicit "Delete cloud data".
if ! aws s3api head-bucket --bucket "$REC_BUCKET" --region "$REGION" >/dev/null 2>&1; then
  say "creating private state bucket $REC_BUCKET"
  aws s3api create-bucket --bucket "$REC_BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
fi
aws s3api put-public-access-block --bucket "$REC_BUCKET" --region "$REGION" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null

# 2) execution role: basic logs + read/write/delete ONLY the rec/* prefix of this bucket.
#    s3:ListBucket (prefix-scoped) is load-bearing: WITHOUT it S3 answers GetObject on a missing
#    key with 403 AccessDenied instead of 404, so the handler could never see "no state yet".
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  say "creating role $ROLE"
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
  say "waiting for role to propagate…"; sleep 12
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name "rec-state-access" --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[
     {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],\"Resource\":\"arn:aws:s3:::${REC_BUCKET}/rec/*\"},
     {\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::${REC_BUCKET}\",\"Condition\":{\"StringLike\":{\"s3:prefix\":\"rec/*\"}}}
   ]}" >/dev/null
ROLE_ARN="arn:aws:iam::${ACCT}:role/${ROLE}"

# 3) package + create/update the function (index.mjs only; @aws-sdk is bundled in the runtime).
#    Resolve the enrollment secret FIRST: $REC_ENROLL_SECRET wins (deliberate rotation), else the
#    value already deployed (so a plain code re-run never invalidates shipped builds), else mint.
ENROLL="${REC_ENROLL_SECRET:-}"
if [ -z "$ENROLL" ]; then
  ENROLL="$(aws lambda get-function-configuration --function-name "$FN" --region "$REGION" \
    --query 'Environment.Variables.REC_ENROLL_SECRET' --output text 2>/dev/null || true)"
  [ "$ENROLL" = "None" ] && ENROLL=""
fi
if [ -z "$ENROLL" ]; then
  ENROLL="$(openssl rand -hex 24)"
  say "MINTED a new enrollment secret — paste it into Config.recEngineEnrollSecret:"
  say "    $ENROLL"
fi
ZIP="$(mktemp -d)/fn.zip"; ( cd "$SELF" && zip -q -r "$ZIP" index.mjs )
ENVVARS="Variables={REC_BUCKET=$REC_BUCKET,FEATURES_URL=$FEATURES_URL,REC_ENROLL_SECRET=$ENROLL}"
if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  say "updating function code"
  aws lambda update-function-code --function-name "$FN" --zip-file "fileb://$ZIP" --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --timeout 60 --memory-size 1024 --environment "$ENVVARS" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
else
  say "creating function $FN"
  aws lambda create-function --function-name "$FN" --runtime nodejs20.x --role "$ROLE_ARN" \
    --handler index.handler --timeout 60 --memory-size 1024 --environment "$ENVVARS" \
    --zip-file "fileb://$ZIP" --region "$REGION" >/dev/null
  aws lambda wait function-active --function-name "$FN" --region "$REGION"
fi

# 4) HTTP API ($default catch-all -> Lambda; the handler dispatches on rawPath).
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null)"
if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
  say "creating HTTP API $API_NAME -> $FN"
  API_ID="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP --target "$LAMBDA_ARN" --region "$REGION" --query ApiId --output text)"
fi
aws lambda add-permission --function-name "$FN" --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${REGION}:${ACCT}:${API_ID}/*" --region "$REGION" >/dev/null 2>&1 || true
# Blast-radius cap: the account default is 10k rps, which for a one-user endpoint is only ever
# an abuse budget. One device flushes every 10 minutes, so 20 rps / 40 burst is enormous headroom.
aws apigatewayv2 update-stage --api-id "$API_ID" --stage-name '$default' --region "$REGION" \
  --default-route-settings ThrottlingRateLimit=20,ThrottlingBurstLimit=40 >/dev/null
API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
echo "$API_URL" > "$SELF/.endpoint-url.txt"
say "done. Endpoint: $API_URL  (also written to scripts/lambda/rec-engine/.endpoint-url.txt)"
say "verify: curl -s $API_URL/health"
say "NEXT: paste the endpoint into Config.recEngineBase (apple/PocketDJ/Support/Config.swift)"
say "      and make sure Config.recEngineEnrollSecret matches REC_ENROLL_SECRET above."
