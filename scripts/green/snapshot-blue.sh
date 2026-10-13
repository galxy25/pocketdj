#!/usr/bin/env bash
# READ-ONLY snapshot of the blue PocketDJ stack's configuration into scripts/green/blue-snapshot/.
# provision.sh builds green FROM THIS SNAPSHOT, so green can be re-provisioned after blue is gone.
# Secrets are never written here: Lambda env values for REC_ENROLL_SECRET are replaced by a
# marker, and Secrets Manager values are not read at all (provision.sh pipes them blue→green).
#
#   bash scripts/green/snapshot-blue.sh
. "$(dirname "$0")/lib.sh"
rm -rf "$SNAP"; mkdir -p "$SNAP"/{s3,lambda,apigw,sqs,cf,iam,ec2,events,aoss,r53,ses}

say "S3 bucket configs"
for n in $BUCKETS; do
  bk=$(bbucket "$n"); d="$SNAP/s3/$n"; mkdir -p "$d"
  b s3api get-bucket-policy --bucket "$bk" --output json 2>/dev/null | jq '.Policy|fromjson' > "$d/policy.json" || rm -f "$d/policy.json"
  b s3api get-bucket-lifecycle-configuration --bucket "$bk" --output json 2>/dev/null | jq '{Rules}' > "$d/lifecycle.json" || rm -f "$d/lifecycle.json"
  b s3api get-bucket-cors --bucket "$bk" --output json 2>/dev/null > "$d/cors.json" || rm -f "$d/cors.json"
  b s3api get-bucket-website --bucket "$bk" --output json 2>/dev/null | jq '{IndexDocument,ErrorDocument}' > "$d/website.json" || rm -f "$d/website.json"
  b s3api get-bucket-logging --bucket "$bk" --output json 2>/dev/null | jq 'select(.LoggingEnabled)' > "$d/logging.json"; [ -s "$d/logging.json" ] || rm -f "$d/logging.json"
  b s3api get-public-access-block --bucket "$bk" --output json 2>/dev/null > "$d/pab.json" || rm -f "$d/pab.json"
  b s3api get-bucket-ownership-controls --bucket "$bk" --output json > "$d/ownership.json"
  b s3api get-bucket-encryption --bucket "$bk" --output json > "$d/encryption.json"
  b s3api get-bucket-versioning --bucket "$bk" --output json > "$d/versioning.json"
done

say "Lambda configs (secret env values masked)"
for fn in pocketdj-rec-engine pocketdj-am-playlist-sync pocketdj-search-proxy pocketdj-mail-forwarder pocketdj-listening-pockets; do
  b lambda get-function-configuration --function-name "$fn" --output json \
    | jq '{FunctionName,Runtime,Handler,MemorySize,Timeout,Architectures,EphemeralStorage,
           Role:(.Role|split("/")|last),
           Environment:{Variables:((.Environment.Variables//{})|with_entries(if .key=="REC_ENROLL_SECRET" then .value="<copied-from-blue-at-provision>" else . end))}}' \
    > "$SNAP/lambda/$fn.json"
  b lambda get-policy --function-name "$fn" --output json | jq '.Policy|fromjson' > "$SNAP/lambda/$fn.policy.json"
done

say "API Gateway (HTTP APIs)"
b apigatewayv2 get-apis --output json | jq '[.Items[]|select(.Name|startswith("pocketdj-"))|{Name,ApiId,ProtocolType}]' > "$SNAP/apigw/apis.json"
for id in $(jq -r '.[].ApiId' "$SNAP/apigw/apis.json"); do
  name=$(jq -r --arg i "$id" '.[]|select(.ApiId==$i)|.Name' "$SNAP/apigw/apis.json")
  { b apigatewayv2 get-routes --api-id "$id" --output json | jq '[.Items[]|{RouteKey,Target,AuthorizationType}]' > "$SNAP/apigw/$name.routes.json"; }
  b apigatewayv2 get-integrations --api-id "$id" --output json \
    | jq '[.Items[]|{IntegrationId,IntegrationType,PayloadFormatVersion,TimeoutInMillis,Function:(.IntegrationUri|split(":")|last)}]' > "$SNAP/apigw/$name.integrations.json"
  b apigatewayv2 get-stages --api-id "$id" --output json | jq '[.Items[]|{StageName,AutoDeploy,DefaultRouteSettings}]' > "$SNAP/apigw/$name.stages.json"
done

say "SQS"
for q in pocketdj-stem-jobs-dlq pocketdj-timbre-jobs-dlq pocketdj-stem-jobs pocketdj-stem-results pocketdj-timbre-jobs pocketdj-timbre-results; do
  url="https://sqs.${R}.amazonaws.com/${BA}/${q}"
  b sqs get-queue-attributes --queue-url "$url" --attribute-names All --output json \
    | jq '.Attributes|{VisibilityTimeout,MaximumMessageSize,MessageRetentionPeriod,DelaySeconds,ReceiveMessageWaitTimeSeconds,SqsManagedSseEnabled,RedrivePolicy}|with_entries(select(.value!=null))' > "$SNAP/sqs/$q.json"
done

say "CloudFront"
for id in E123GKAO9JVETP E1SP8M1SIF7Q8D E9XDXX3A506H6 E9L9V188S55F7 E1XIWBBPFOJ07E; do
  b cloudfront get-distribution-config --id "$id" --output json | jq '.DistributionConfig' > "$SNAP/cf/$id.json"
done
b cloudfront get-function --name pocketdj-subpath-rewrite --stage LIVE "$SNAP/cf/pocketdj-subpath-rewrite.js" >/dev/null
b cloudfront list-origin-access-controls --output json \
  | jq '[.OriginAccessControlList.Items[]|select(.Name|startswith("pocketdj-"))]' > "$SNAP/cf/oac.json"

say "IAM (roles, inline policies, users' inline policies)"
for r in pocketdj-am-playlist-sync-role pocketdj-listening-pockets-role pocketdj-mail-forwarder pocketdj-rec-engine-role pocketdj-search-proxy-role pocketdj-stem-worker; do
  d="$SNAP/iam/role-$r"; mkdir -p "$d"
  b iam get-role --role-name "$r" --output json | jq '.Role.AssumeRolePolicyDocument' > "$d/trust.json"
  b iam list-attached-role-policies --role-name "$r" --output json | jq '[.AttachedPolicies[].PolicyArn]' > "$d/attached.json"
  for p in $(b iam list-role-policies --role-name "$r" --output json | jq -r '.PolicyNames[]'); do
    b iam get-role-policy --role-name "$r" --policy-name "$p" --output json | jq '.PolicyDocument' > "$d/inline.$p.json"
  done
done
for u in djpocketsearch pocketdj-diag-writer; do
  d="$SNAP/iam/user-$u"; mkdir -p "$d"
  for p in $(b iam list-user-policies --user-name "$u" --output json | jq -r '.PolicyNames[]'); do
    b iam get-user-policy --user-name "$u" --policy-name "$p" --output json | jq '.PolicyDocument' > "$d/inline.$p.json"
  done
done

say "EC2 launch templates + SG"
for t in pocketdj-stem-worker pocketdj-timbre-worker; do
  b ec2 describe-launch-template-versions --launch-template-name "$t" --versions '$Default' --output json \
    | jq '.LaunchTemplateVersions[0].LaunchTemplateData' > "$SNAP/ec2/$t.json"
  jq -r '.UserData' "$SNAP/ec2/$t.json" | base64 -d > "$SNAP/ec2/$t.userdata.sh"
done
b ec2 describe-security-groups --filters Name=group-name,Values=pocketdj-stem-sg --output json \
  | jq '.SecurityGroups[0]|{GroupName,Description,IpPermissions,IpPermissionsEgress}' > "$SNAP/ec2/pocketdj-stem-sg.json"
b ec2 describe-subnets --output json | jq '[.Subnets[]|{SubnetId,AvailabilityZone}]' > "$SNAP/ec2/subnets.json"

say "EventBridge"
b events describe-rule --name pocketdj-listening-pockets-nightly --output json \
  | jq '{Name,ScheduleExpression,State,Description}' > "$SNAP/events/pocketdj-listening-pockets-nightly.json"
b events list-targets-by-rule --rule pocketdj-listening-pockets-nightly --output json \
  | jq '[.Targets[]|{Id,Input,Function:(.Arn|split(":")|last)}]' > "$SNAP/events/pocketdj-listening-pockets-nightly.targets.json"

say "OpenSearch Serverless"
b opensearchserverless get-access-policy --name pocketdj-data --type data --output json | jq '.accessPolicyDetail.policy' > "$SNAP/aoss/data.json"
b opensearchserverless get-security-policy --name pocketdj-net --type network --output json | jq '.securityPolicyDetail.policy' > "$SNAP/aoss/net.json"
b opensearchserverless batch-get-collection --names pocketdj-search --output json \
  | jq '.collectionDetails[0]|{name,type,standbyReplicas,collectionGroupName,description}' > "$SNAP/aoss/collection.json"

say "Route 53 (pocket-dj.com) + SES"
Z=$(b route53 list-hosted-zones-by-name --dns-name pocket-dj.com --output json | jq -r '.HostedZones[]|select(.Name=="pocket-dj.com.")|.Id' | head -1)
b route53 list-resource-record-sets --hosted-zone-id "$Z" --output json | jq '.ResourceRecordSets' > "$SNAP/r53/rrsets.json"
b route53 get-hosted-zone --id "$Z" --output json | jq '{Id:.HostedZone.Id,NameServers:.DelegationSet.NameServers}' > "$SNAP/r53/zone.json"
b ses describe-active-receipt-rule-set --output json \
  | jq '[.Rules[]|select(.Recipients|index("pocket-dj.com"))]' > "$SNAP/ses/pocketdj-rules.json"
b ses list-identities --output json | jq '[.Identities[]|select(test("pocket-dj"))]' > "$SNAP/ses/identities.json"

say "snapshot written to $SNAP"
