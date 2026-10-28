#!/usr/bin/env bash
# Deploy the PocketDJ profile-sync Lambda (S3 document store behind an API Gateway HTTP API) — the
# server for Android's S3CloudDocDatabase. Re-runnable: every step is create-or-update. Contract:
# docs/design/profile-sync-s3.md.
#
#   POCKETDJ_ENV=green AWS_PROFILE=llc scripts/lambda/profile-sync/deploy.sh   (green is default)
#
# Enrollment capability token (ENROLL_SECRET): $PROFILE_SYNC_ENROLL_SECRET wins (deliberate rotation),
# else the value already on the function is preserved, else a new one is minted and printed ONCE
# (SHOW_SECRET=1 reprints). The Android build embeds it like Config.recEngineEnrollSecret.
# MAX_PROFILES (default 50) caps distinct enrolled profiles (preserved across redeploys).
# Afterwards the new base URL is written into config/endpoints.<env>.json as optional `profileSyncBase`
# and the doc is re-validated with the PWA validator (scripts/validate-endpoints.ts).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/aws-env.sh"
export AWS_PROFILE="${AWS_PROFILE:-$PDJ_PROFILE}"
REGION="$PDJ_REGION"; ACCT="$PDJ_ACCOUNT"
FN="pocketdj-profile-sync"; ROLE="pocketdj-profile-sync-role"; API_NAME="pocketdj-profile-sync"
BUCKET="pocketdj-profiles-${ACCT}"
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCT}:function:${FN}"
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../../.." && pwd)"
say(){ echo "[deploy-profile-sync] $*"; }

# 1) private bucket: block all public access, default SSE.
if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
  say "creating private bucket $BUCKET"
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
fi
aws s3api put-public-access-block --bucket "$BUCKET" --region "$REGION" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
aws s3api put-bucket-encryption --bucket "$BUCKET" --region "$REGION" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null

# 2) execution role: logs + read/write/list ONLY profiles/* in this bucket.
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  say "creating role $ROLE"
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
  say "waiting for role to propagate…"; sleep 12
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name "profile-sync-access" --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[
     {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],\"Resource\":\"arn:aws:s3:::${BUCKET}/profiles/*\"},
     {\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::${BUCKET}\",\"Condition\":{\"StringLike\":{\"s3:prefix\":\"profiles/*\"}}}
   ]}" >/dev/null
ROLE_ARN="arn:aws:iam::${ACCT}:role/${ROLE}"

# 3) enrollment secret + cap (preserve-then-default).
FN_EXISTS=0
aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1 && FN_EXISTS=1
# Errors are NOT swallowed for an existing function: an unreadable secret must abort, never be re-minted.
getenvvar(){ aws lambda get-function-configuration --function-name "$FN" --region "$REGION" \
  --query "Environment.Variables.$1" --output text; }
ENROLL="${PROFILE_SYNC_ENROLL_SECRET:-}"
if [ -z "$ENROLL" ] && [ "$FN_EXISTS" = 1 ]; then
  ENROLL="$(getenvvar ENROLL_SECRET)" || { say "ERROR: function exists but ENROLL_SECRET is unreadable; refusing to mint a new one (set PROFILE_SYNC_ENROLL_SECRET to rotate deliberately)"; exit 1; }
  [ "$ENROLL" = "None" ] && ENROLL=""
  [ -z "$ENROLL" ] && { say "ERROR: function exists without ENROLL_SECRET; set PROFILE_SYNC_ENROLL_SECRET explicitly"; exit 1; }
fi
MINTED=0
if [ -z "$ENROLL" ]; then ENROLL="$(openssl rand -hex 24)"; MINTED=1; fi
FP="$(printf %s "$ENROLL" | shasum -a 256 | cut -c1-16)"
if [ "$MINTED" = 1 ]; then say "MINTED enrollment secret (sha256 ${FP}…): $ENROLL"
else say "enrollment secret unchanged (sha256 ${FP}…)"; [ "${SHOW_SECRET:-0}" = 1 ] && say "    $ENROLL"; fi
MAXP="${MAX_PROFILES:-}"
if [ -z "$MAXP" ]; then
  [ "$FN_EXISTS" = 1 ] && MAXP="$(getenvvar MAX_PROFILES 2>/dev/null || true)"
  { [ "${MAXP:-None}" = "None" ] || [ -z "$MAXP" ]; } && MAXP=50
fi

# 4) package + create/update the function (index.mjs only; @aws-sdk v3 is in the runtime).
ZIP="$(mktemp -d)/fn.zip"; ( cd "$SELF" && zip -q -r "$ZIP" index.mjs )
ENVVARS="Variables={PROFILE_BUCKET=$BUCKET,ENROLL_SECRET=$ENROLL,MAX_PROFILES=$MAXP}"
if [ "$FN_EXISTS" = 1 ]; then
  say "updating function"
  aws lambda update-function-code --function-name "$FN" --zip-file "fileb://$ZIP" --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --timeout 20 --memory-size 256 --environment "$ENVVARS" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
else
  say "creating function $FN"
  aws lambda create-function --function-name "$FN" --runtime nodejs20.x --role "$ROLE_ARN" \
    --handler index.handler --timeout 20 --memory-size 256 --environment "$ENVVARS" \
    --zip-file "fileb://$ZIP" --region "$REGION" >/dev/null
  aws lambda wait function-active --function-name "$FN" --region "$REGION"
fi

# 5) HTTP API ($default catch-all -> Lambda; the handler dispatches on rawPath).
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null)"
if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
  say "creating HTTP API $API_NAME -> $FN"
  API_ID="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP --target "$LAMBDA_ARN" --region "$REGION" --query ApiId --output text)"
fi
aws lambda add-permission --function-name "$FN" --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${REGION}:${ACCT}:${API_ID}/*" --region "$REGION" >/dev/null 2>&1 || true
API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
echo "$API_URL" > "$SELF/.endpoint-url.txt"

# 6) publish the optional endpoint key and re-validate with the PWA validator.
CFG="$ROOT/config/endpoints.${PDJ_ENV}.json"
if [ -f "$CFG" ]; then
  CFG="$CFG" URL="$API_URL" node -e '
    const fs=require("fs");const p=process.env.CFG;const d=JSON.parse(fs.readFileSync(p,"utf8"));
    d.endpoints.profileSyncBase=process.env.URL;fs.writeFileSync(p,JSON.stringify(d,null,2)+"\n");'
  say "wrote profileSyncBase into $CFG"
  ( cd "$ROOT" && npx --no-install tsx scripts/validate-endpoints.ts "$CFG" ) || { say "ERROR: validate-endpoints failed — fix the doc before deploying it"; exit 1; }
fi
say "done. Endpoint: $API_URL   verify: curl -s $API_URL/health"
say "then: run deploy.sh for the PWA so the endpoint doc (config/endpoints.json on S3 (scripts/deploy.sh)) carries profileSyncBase."
