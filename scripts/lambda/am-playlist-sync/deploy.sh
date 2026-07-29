#!/usr/bin/env bash
# Deploy the PocketDJ Apple Music playlist-sync Lambda behind an API Gateway HTTP API — the
# server half of WS2 (bidirectional PocketDJ <-> Apple Music library-playlist sync), replacing the
# iMac/Tailscale /am-sync path with an on-demand AWS endpoint. Cloned from deploy-search-proxy.sh.
#
# Security model: the endpoint is PUBLIC (like the existing rip-server /musickit-token). Every
# /v1/me library call requires the caller's own Music-User-Token (minted on-device, sent per call,
# never stored) — Apple rejects any request without a valid one, and a token only affects its own
# owner's library. The developer token this Lambda mints is app-wide and useless on its own. There
# is no host-library read to protect, so no shared app secret is shipped in the binary.
#
# Secrets Manager holds ONLY the MusicKit signing material { p8, kid, team } — the .p8 never ships
# in the deploy artifact. Idempotent-ish; safe to re-run to update code.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-levi}"
REGION="us-west-2"; ACCT="011183829623"
FN="pocketdj-am-playlist-sync"; ROLE="pocketdj-am-playlist-sync-role"; API_NAME="pocketdj-am-playlist-sync"
SECRET_ID="pocketdj/am-playlist-sync"
# Private bucket for async job results (POST /pull|/push -> worker writes here -> GET /job/{id} reads).
JOBS_BUCKET="pocketdj-am-sync-jobs-${ACCT}"
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCT}:function:${FN}"
SELF="$(cd "$(dirname "$0")" && pwd)"
P8_PATH="${MUSICKIT_P8:-$HOME/.appstoreconnect/private_keys/AuthKey_9JRN4H68X4.p8}"
KID="${MUSICKIT_KID:-9JRN4H68X4}"; TEAM="${MUSICKIT_TEAM:-EC27UF79GL}"
say(){ echo "[deploy-am-sync] $*"; }

[ -f "$P8_PATH" ] || { echo "MusicKit .p8 not found at $P8_PATH (set MUSICKIT_P8)"; exit 1; }

# 1) Secrets Manager: upsert { p8, kid, team } (the .p8 has newlines -> build JSON with node).
say "upserting secret $SECRET_ID"
SECRET_JSON="$(P8="$(cat "$P8_PATH")" KID="$KID" TEAM="$TEAM" node -e \
  'process.stdout.write(JSON.stringify({p8:process.env.P8,kid:process.env.KID,team:process.env.TEAM}))')"
if aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$REGION" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "$SECRET_JSON" --region "$REGION" >/dev/null
else
  aws secretsmanager create-secret --name "$SECRET_ID" --secret-string "$SECRET_JSON" --region "$REGION" >/dev/null
fi
SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$REGION" --query ARN --output text)"

# 1b) private jobs bucket (async job results). Block ALL public access; expire objects after 1 day.
if ! aws s3api head-bucket --bucket "$JOBS_BUCKET" --region "$REGION" >/dev/null 2>&1; then
  say "creating private jobs bucket $JOBS_BUCKET"
  aws s3api create-bucket --bucket "$JOBS_BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
fi
aws s3api put-public-access-block --bucket "$JOBS_BUCKET" --region "$REGION" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
aws s3api put-bucket-lifecycle-configuration --bucket "$JOBS_BUCKET" --region "$REGION" \
  --lifecycle-configuration '{"Rules":[{"ID":"expire-jobs","Status":"Enabled","Filter":{"Prefix":"am-sync-jobs/"},"Expiration":{"Days":1}}]}' >/dev/null

# 2) execution role: basic logs + read ONLY this secret.
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  say "creating role $ROLE"
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
  say "waiting for role to propagate…"; sleep 12
fi
# (Re)apply the least-privilege policy: read ONLY this secret, read/write ONLY the job objects, and
# self-invoke ONLY this function (async worker fan-out).
aws iam put-role-policy --role-name "$ROLE" --policy-name "am-sync-access" --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[
     {\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"${SECRET_ARN%-*}-*\"},
     {\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::${JOBS_BUCKET}/am-sync-jobs/*\"},
     {\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"${LAMBDA_ARN}\"}
   ]}" >/dev/null
# Remove the old narrower policy name if it lingers from a prior deploy (ignore if absent).
aws iam delete-role-policy --role-name "$ROLE" --policy-name "read-am-sync-secret" >/dev/null 2>&1 || true
ROLE_ARN="arn:aws:iam::${ACCT}:role/${ROLE}"

# 3) package + create/update the function (index.mjs only; @aws-sdk is bundled in the runtime).
ZIP="$(mktemp -d)/fn.zip"; ( cd "$SELF" && zip -q -r "$ZIP" index.mjs )
# timeout 300: the async WORKER path does the full 100+-call pull; the API-facing path returns in <1s.
ENVVARS="Variables={SECRET_ID=$SECRET_ID,JOBS_BUCKET=$JOBS_BUCKET}"
if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  say "updating function code"
  aws lambda update-function-code --function-name "$FN" --zip-file "fileb://$ZIP" --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --timeout 300 --memory-size 256 --environment "$ENVVARS" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
else
  say "creating function $FN"
  aws lambda create-function --function-name "$FN" --runtime nodejs20.x --role "$ROLE_ARN" \
    --handler index.handler --timeout 300 --memory-size 256 --environment "$ENVVARS" \
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
say "done. Endpoint: $API_URL  (also written to scripts/lambda/am-playlist-sync/.endpoint-url.txt)"
say "verify: curl -s $API_URL/health"
