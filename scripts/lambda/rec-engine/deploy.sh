#!/usr/bin/env bash
# Deploy the PocketDJ RECOMMENDATION-ENGINE Lambda behind an API Gateway HTTP API (WS-E).
# Cloned from scripts/lambda/am-playlist-sync/deploy.sh, minus all Secrets Manager steps —
# this endpoint holds no Apple credentials; auth is the per-profile TOFU bearer key the app
# mints (see index.mjs header).
#
# Key recovery (single-user pragmatics): a genuinely wedged key — two devices enabled the
# engine before CloudKit synced the rec-key doc AND the loser bound first — is fixed either by
# temporarily setting REC_ALLOW_REBIND=1 on the function's env (dev only) or by deleting the
# profile's rec/state/<hash>.json object from the bucket. "Delete cloud data" in-app needs the
# matching key, so it can't unwedge itself.
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
ZIP="$(mktemp -d)/fn.zip"; ( cd "$SELF" && zip -q -r "$ZIP" index.mjs )
ENVVARS="Variables={REC_BUCKET=$REC_BUCKET,FEATURES_URL=$FEATURES_URL}"
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
API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
echo "$API_URL" > "$SELF/.endpoint-url.txt"
say "done. Endpoint: $API_URL  (also written to scripts/lambda/rec-engine/.endpoint-url.txt)"
say "verify: curl -s $API_URL/health"
say "NEXT: paste the endpoint into Config.recEngineBase (apple/PocketDJ/Support/Config.swift)"
