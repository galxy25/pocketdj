#!/usr/bin/env bash
# Deploy the PocketDJ online-search proxy: a tiny Lambda behind an API Gateway HTTP API,
# used as the CloudFront /pocketdj/* origin so the PWA's browser search works against the
# NextGen aoss endpoint. See scripts/lambda/search-proxy/index.mjs for the why.
#
# Why API Gateway (not a Function URL / not direct-to-aoss):
#   • Direct CloudFront -> aoss FAILS on NextGen: CloudFront injects an `x-amz-cf-id`
#     header the browser can't sign; NextGen rejects it. The Lambda makes a CLEAN outbound
#     request to aoss (forwarding only the browser's SigV4 headers), so aoss sees exactly
#     what the browser signed.
#   • This account BLOCKS public Lambda Function URLs (verified: even a fresh NONE-auth URL
#     403s), so the Function-URL approach is out. API Gateway HTTP API is public by default.
#   • HTTP API cost is ~$1/million requests, no idle charge (≈ $0.001/mo at this volume).
#
# The browser keeps signing for the aoss host (search-config.json) and fetching the
# same-origin /pocketdj path — no PWA change. Idempotent-ish.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-levi}"
REGION="us-west-2"; ACCT="011183829623"
FN="pocketdj-search-proxy"; ROLE="pocketdj-search-proxy-role"; API_NAME="pocketdj-search"
SELF="$(cd "$(dirname "$0")" && pwd)"
AOSS_HOST="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('public/search-config.json','utf8')).host)")"
say(){ echo "[deploy-proxy] $*"; }

# 1) execution role (basic logs only — the Lambda re-forwards the browser's signature)
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  say "creating role $ROLE"
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
  say "waiting for role to propagate…"; sleep 12
fi
ROLE_ARN="arn:aws:iam::${ACCT}:role/${ROLE}"

# 2) package + create/update the function
ZIP="$(mktemp -d)/fn.zip"; ( cd "$SELF/search-proxy" && zip -q -r "$ZIP" index.mjs )
if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  say "updating function code + AOSS_HOST=$AOSS_HOST"
  aws lambda update-function-code --function-name "$FN" --zip-file "fileb://$ZIP" --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" --environment "Variables={AOSS_HOST=$AOSS_HOST}" >/dev/null
else
  say "creating function $FN (AOSS_HOST=$AOSS_HOST)"
  aws lambda create-function --function-name "$FN" --runtime nodejs20.x --role "$ROLE_ARN" \
    --handler index.handler --timeout 20 --memory-size 256 --environment "Variables={AOSS_HOST=$AOSS_HOST}" \
    --zip-file "fileb://$ZIP" --region "$REGION" >/dev/null
  aws lambda wait function-active --function-name "$FN" --region "$REGION"
fi
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCT}:function:${FN}"

# 3) HTTP API (create-api --target wires route + AWS_PROXY integration + auto-deploy + invoke perm)
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null)"
if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
  say "creating HTTP API $API_NAME -> $FN"
  API_ID="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP --target "$LAMBDA_ARN" --region "$REGION" --query ApiId --output text)"
fi
aws lambda add-permission --function-name "$FN" --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${REGION}:${ACCT}:${API_ID}/*" --region "$REGION" >/dev/null 2>&1 || true
API_DOMAIN="${API_ID}.execute-api.${REGION}.amazonaws.com"
say "API endpoint: https://${API_DOMAIN}"

# 4) point CloudFront /pocketdj origins at the API GW (dev + prod)
say "repointing CloudFront /pocketdj origins -> $API_DOMAIN"
python3 - "$API_DOMAIN" <<PY
import sys, botocore.session
api = sys.argv[1]
cf = botocore.session.Session(profile='levi').create_client('cloudfront')
for dist_id in ['E123GKAO9JVETP', 'E1SP8M1SIF7Q8D']:
    r = cf.get_distribution_config(Id=dist_id); etag, cfg = r['ETag'], r['DistributionConfig']
    for o in cfg['Origins']['Items']:
        if o['Id'] == 'pocketdj-aoss' or any(s in o['DomainName'] for s in ('.on.aws','.aoss.','lambda-url','execute-api')):
            o['DomainName'] = api
            if 'CustomOriginConfig' in o:
                o['CustomOriginConfig']['OriginProtocolPolicy'] = 'https-only'; o['CustomOriginConfig']['HTTPSPort'] = 443
    cf.update_distribution(Id=dist_id, DistributionConfig=cfg, IfMatch=etag)
    cf.create_invalidation(DistributionId=dist_id, InvalidationBatch={'Paths':{'Quantity':1,'Items':['/pocketdj/*']},'CallerReference':f'apigw-{dist_id}-{etag[:8]}'})
    print(f"  {dist_id} -> {api}")
PY
say "done. CloudFront redeploy ~3-6 min, then browser /pocketdj/_search works on NextGen."
