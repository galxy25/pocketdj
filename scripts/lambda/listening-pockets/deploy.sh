#!/usr/bin/env bash
# Deploy the PocketDJ LISTENING POCKETS Lambda and mount it on the EXISTING rec-engine HTTP API.
# Cloned from scripts/lambda/rec-engine/deploy.sh. NEEDS LEVI'S APPROVAL TO RUN — it creates an
# IAM role, a function, two API routes and an EventBridge rule in the POCKETDJ_ENV account
# (blue: 011183829623).
#
#   scripts/lambda/listening-pockets/deploy.sh
#
# What it does (idempotent; safe to re-run to update code):
#   1. checks the rec-engine state bucket exists (this service writes ONLY under its `pockets/` prefix)
#   2. role pocketdj-listening-pockets-role: basic logs; Get/Put/Delete on pockets/*; ListBucket
#      with the prefix condition pockets/* (load-bearing: without it a missing key reads as 403, not
#      404, and "no state yet" becomes an error); lambda:InvokeFunction on ITSELF (async compute +
#      nightly continuations)
#   3. function pocketdj-listening-pockets (nodejs20.x, 1024 MB, 120 s) from the six modules here
#   4. API: an AWS_PROXY (payload 2.0) integration on the API named pocketdj-rec-engine, routes
#      `ANY /pockets` and `ANY /pockets/{proxy+}`; `$default` (the rec engine) is left untouched
#   5. EventBridge rule pocketdj-listening-pockets-nightly, cron(30 11 * * ? *) = 04:30 PDT,
#      input {"job":"nightly"}
#   6. curl $API/pockets/health
#
# ENROLLMENT SECRET: REC_ENROLL_SECRET is READ FROM THE DEPLOYED pocketdj-rec-engine FUNCTION, never
# minted here — the app ships exactly one secret (`Config.recEngineEnrollSecret`) and presents it to
# both services. If the rec engine has none, this aborts. Only its sha256 fingerprint is printed.
# MAX_PROFILES: preserved from this function's own config across re-runs (default 10); export
# MAX_PROFILES=<n> to change it.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/aws-env.sh"   # PDJ_* fallbacks for POCKETDJ_ENV (default blue)
export AWS_PROFILE="${AWS_PROFILE:-$PDJ_PROFILE}"
REGION="$PDJ_REGION"; ACCT="$PDJ_ACCOUNT"
FN="pocketdj-listening-pockets"; ROLE="pocketdj-listening-pockets-role"
REC_FN="pocketdj-rec-engine"; API_NAME="pocketdj-rec-engine"
REC_BUCKET="pocketdj-rec-${ACCT}"
FEATURES_URL="${PDJ_CDN_PROD}/rec-features.json"
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCT}:function:${FN}"
RULE="pocketdj-listening-pockets-nightly"
SELF="$(cd "$(dirname "$0")" && pwd)"
say(){ echo "[deploy-listening-pockets] $*"; }
die(){ echo "[deploy-listening-pockets] ERROR: $*" >&2; exit 1; }

# 0) the tests must pass before anything ships.
say "running the test suite"
node --test "$SELF/test-listening-pockets.mjs" >/dev/null || die "tests failed — not deploying"

# 1) the bucket is the rec engine's; it must already exist (that deploy creates + locks it down).
aws s3api head-bucket --bucket "$REC_BUCKET" --region "$REGION" >/dev/null 2>&1 \
  || die "bucket $REC_BUCKET not found — deploy the rec engine first"

# 2) execution role, scoped to pockets/* and to invoking itself.
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  say "creating role $ROLE"
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
  say "waiting for role to propagate…"; sleep 12
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name "pockets-state-access" --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[
     {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],\"Resource\":\"arn:aws:s3:::${REC_BUCKET}/pockets/*\"},
     {\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::${REC_BUCKET}\",\"Condition\":{\"StringLike\":{\"s3:prefix\":\"pockets/*\"}}},
     {\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"${LAMBDA_ARN}\"}
   ]}" >/dev/null
ROLE_ARN="arn:aws:iam::${ACCT}:role/${ROLE}"

# 3) the enrollment secret — the rec engine's, verbatim.
ENROLL="$(aws lambda get-function-configuration --function-name "$REC_FN" --region "$REGION" \
  --query 'Environment.Variables.REC_ENROLL_SECRET' --output text 2>/dev/null || true)"
{ [ "$ENROLL" = "None" ] || [ -z "$ENROLL" ]; } && die "$REC_FN has no REC_ENROLL_SECRET — refusing to mint one (it must equal Config.recEngineEnrollSecret)"
FP="$(printf %s "$ENROLL" | shasum -a 256 | cut -c1-16)"
say "enrollment secret copied from $REC_FN (sha256 ${FP}…)"
MAXP="${MAX_PROFILES:-}"
if [ -z "$MAXP" ]; then
  MAXP="$(aws lambda get-function-configuration --function-name "$FN" --region "$REGION" \
    --query 'Environment.Variables.MAX_PROFILES' --output text 2>/dev/null || true)"
  { [ "$MAXP" = "None" ] || [ -z "$MAXP" ]; } && MAXP="10"
fi
say "profile enrollment cap: $MAXP"

# 4) package + create/update. @aws-sdk (S3, Lambda) is bundled in the nodejs20.x runtime.
ZIP="$(mktemp -d)/fn.zip"
( cd "$SELF" && zip -q "$ZIP" index.mjs params.mjs detect.mjs analyze.mjs features.mjs store.mjs )
ENVVARS="Variables={REC_BUCKET=$REC_BUCKET,FEATURES_URL=$FEATURES_URL,REC_ENROLL_SECRET=$ENROLL,MAX_PROFILES=$MAXP}"
if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  say "updating function code"
  aws lambda update-function-code --function-name "$FN" --zip-file "fileb://$ZIP" --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --timeout 120 --memory-size 1024 --environment "$ENVVARS" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
else
  say "creating function $FN"
  aws lambda create-function --function-name "$FN" --runtime nodejs20.x --role "$ROLE_ARN" \
    --handler index.handler --timeout 120 --memory-size 1024 --environment "$ENVVARS" \
    --zip-file "fileb://$ZIP" --region "$REGION" >/dev/null
  aws lambda wait function-active --function-name "$FN" --region "$REGION"
fi

# 5) mount on the rec-engine HTTP API. Its $default stage auto-deploys, so new routes go live
#    without a deployment step.
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null)"
{ [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; } && die "HTTP API $API_NAME not found — deploy the rec engine first"
INTEG_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
  --query "Items[?IntegrationUri=='${LAMBDA_ARN}'].IntegrationId | [0]" --output text)"
if [ "$INTEG_ID" = "None" ] || [ -z "$INTEG_ID" ]; then
  say "creating integration -> $FN"
  INTEG_ID="$(aws apigatewayv2 create-integration --api-id "$API_ID" --region "$REGION" \
    --integration-type AWS_PROXY --integration-uri "$LAMBDA_ARN" --payload-format-version 2.0 \
    --query IntegrationId --output text)"
fi
for RK in 'ANY /pockets' 'ANY /pockets/{proxy+}'; do
  RID="$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
    --query "Items[?RouteKey=='${RK}'].RouteId | [0]" --output text)"
  if [ "$RID" = "None" ] || [ -z "$RID" ]; then
    say "creating route $RK"
    aws apigatewayv2 create-route --api-id "$API_ID" --region "$REGION" \
      --route-key "$RK" --target "integrations/$INTEG_ID" >/dev/null
  else
    aws apigatewayv2 update-route --api-id "$API_ID" --route-id "$RID" --region "$REGION" \
      --target "integrations/$INTEG_ID" >/dev/null
  fi
done
aws lambda add-permission --function-name "$FN" --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${REGION}:${ACCT}:${API_ID}/*" \
  --region "$REGION" >/dev/null 2>&1 || true

# 6) the nightly recompute.
RULE_ARN="$(aws events put-rule --name "$RULE" --schedule-expression 'cron(30 11 * * ? *)' \
  --state ENABLED --description 'PocketDJ listening pockets: nightly recompute (04:30 PDT)' \
  --region "$REGION" --query RuleArn --output text)"
aws events put-targets --rule "$RULE" --region "$REGION" \
  --targets "[{\"Id\":\"listening-pockets\",\"Arn\":\"${LAMBDA_ARN}\",\"Input\":\"{\\\"job\\\":\\\"nightly\\\"}\"}]" >/dev/null
aws lambda add-permission --function-name "$FN" --statement-id events-nightly --action lambda:InvokeFunction \
  --principal events.amazonaws.com --source-arn "$RULE_ARN" --region "$REGION" >/dev/null 2>&1 || true

API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
say "done. Routes: $API_URL/pockets/*"
say "health: $(curl -s "$API_URL/pockets/health" || echo 'curl failed')"
say "the app uses Config.recEngineBase ($API_URL) + /pockets/…; its enroll secret must fingerprint to $FP"
