#!/usr/bin/env bash
# Provision the GREEN PocketDJ stack (account 623170744161, profile llc) as a copy of blue.
# Idempotent: every phase checks before it creates, and re-running converges configs.
#
#   bash scripts/green/provision.sh all            # everything, in dependency order
#   bash scripts/green/provision.sh s3 iam sqs …   # selected phases
#   GRANT=1 bash scripts/green/provision.sh s3-policies   # add the TEMPORARY blue→green copy grant
#   bash scripts/green/provision.sh s3-policies           # (re)apply policies WITHOUT the grant
#
# Inputs: scripts/green/blue-snapshot/ (bash scripts/green/snapshot-blue.sh, read-only on blue),
#         scripts/green/lambda-snapshot/*.zip (the exact code deployed in blue).
# Blue is touched ONLY for (a) piping secret values blue→green, never printed (sha256 fingerprints
# only), and only when green does not already hold them.
# Outputs: scripts/green/state/* (ids; no secrets).
. "$(dirname "$0")/lib.sh"
command -v jq >/dev/null || die "jq required"

# ------------------------------------------------------------------------------------------- S3
s3_buckets(){
  for n in $BUCKETS; do
    local bk; bk=$(gbucket "$n"); local d="$SNAP/s3/$n"
    if ! g s3api head-bucket --bucket "$bk" >/dev/null 2>&1; then
      say "create bucket $bk"
      g s3api create-bucket --bucket "$bk" --create-bucket-configuration "LocationConstraint=$R" >/dev/null
    fi
    # Ownership (logs keeps BucketOwnerPreferred: CloudFront standard logging needs ACLs).
    g s3api put-bucket-ownership-controls --bucket "$bk" \
      --ownership-controls "$(jq -c '.OwnershipControls' "$d/ownership.json")"
    # Encryption: SSE-S3 as blue (incl. its SSE-C block when the CLI/S3 accept it).
    g s3api put-bucket-encryption --bucket "$bk" \
      --server-side-encryption-configuration "$(jq -c '.ServerSideEncryptionConfiguration' "$d/encryption.json")" 2>/dev/null \
    || g s3api put-bucket-encryption --bucket "$bk" \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":false}]}'
    # Public access block: mirror exactly (blue's dev-web/prod-web have NONE; rips is all-false).
    if [ -f "$d/pab.json" ]; then
      g s3api put-public-access-block --bucket "$bk" \
        --public-access-block-configuration "$(jq -c '.PublicAccessBlockConfiguration' "$d/pab.json")"
    else
      g s3api delete-public-access-block --bucket "$bk"
    fi
    if [ -f "$d/lifecycle.json" ]; then
      g s3api put-bucket-lifecycle-configuration --bucket "$bk" --lifecycle-configuration "file://$d/lifecycle.json" >/dev/null
    fi
    if [ -f "$d/cors.json" ]; then
      g s3api put-bucket-cors --bucket "$bk" --cors-configuration "file://$d/cors.json"
    fi
    if [ -f "$d/website.json" ]; then
      g s3api put-bucket-website --bucket "$bk" --website-configuration "file://$d/website.json"
    fi
  done
}

# Policies are built from blue's with the account id swapped; OAC statements reference the GREEN
# distribution (looked up by comment), so this phase re-runs after `cf`. GRANT=1 appends the
# temporary statement that lets blue's Developer user write the copy (removed by re-running
# without GRANT).
s3_policy_doc(){
  local n="$1" bk; bk=$(gbucket "$n"); local f="$SNAP/s3/$n/policy.json"
  local base='[]'
  if [ -f "$f" ]; then
    base=$(to_green < "$f" | jq -c '.Statement')
    # OAC: replace the distribution ARN with green's, or drop the statement until it exists.
    local bdist gdist
    bdist=$(jq -r '[.Statement[]|.Condition.StringEquals["AWS:SourceArn"]//empty]|first//empty' "$f" | sed 's#.*/##')
    if [ -n "$bdist" ]; then
      local comment; comment="$(jq -r '.Comment' "$SNAP/cf/$bdist.json") [green]"
      gdist=$(cf_id_by_comment "$comment")
      if [ -n "$gdist" ]; then
        base=$(jq -c --arg b "arn:aws:cloudfront::${GA}:distribution/$bdist" --arg g "arn:aws:cloudfront::${GA}:distribution/$gdist" \
          'map(if .Condition.StringEquals["AWS:SourceArn"]==$b then .Condition.StringEquals["AWS:SourceArn"]=$g else . end)' <<<"$base")
      else
        base=$(jq -c 'map(select(.Condition.StringEquals["AWS:SourceArn"]==null))' <<<"$base")
      fi
    fi
  fi
  if [ "${GRANT:-0}" = "1" ]; then
    base=$(jq -c --arg bk "$bk" --arg p "arn:aws:iam::${BA}:user/Developer" '. + [
      {"Sid":"TempBlueMigrationCopy","Effect":"Allow","Principal":{"AWS":$p},
       "Action":["s3:PutObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],"Resource":("arn:aws:s3:::"+$bk+"/*")},
      {"Sid":"TempBlueMigrationList","Effect":"Allow","Principal":{"AWS":$p},
       "Action":["s3:ListBucket","s3:ListBucketMultipartUploads","s3:GetBucketLocation"],"Resource":("arn:aws:s3:::"+$bk)}]' <<<"$base")
  fi
  jq -c '{Version:"2012-10-17",Statement:.}' <<<"$base"
}
s3_policies(){
  for n in $BUCKETS; do
    local bk doc; bk=$(gbucket "$n"); doc=$(s3_policy_doc "$n")
    if [ "$(jq '.Statement|length' <<<"$doc")" = "0" ]; then
      g s3api delete-bucket-policy --bucket "$bk"
      say "policy $bk: none"
    else
      g s3api put-bucket-policy --bucket "$bk" --policy "$doc"
      say "policy $bk: $(jq -r '[.Statement[].Sid//"-"]|join(",")' <<<"$doc")"
    fi
  done
}
s3_logging(){
  for n in $BUCKETS; do
    local f="$SNAP/s3/$n/logging.json"; [ -f "$f" ] || continue
    g s3api put-bucket-logging --bucket "$(gbucket "$n")" --bucket-logging-status "$(to_green < "$f" | jq -c .)"
  done
}

# ------------------------------------------------------------------------------------------ IAM
iam_roles(){
  for d in "$SNAP"/iam/role-*; do
    local r; r=$(basename "$d"); r=${r#role-}
    if ! g iam get-role --role-name "$r" >/dev/null 2>&1; then
      say "create role $r"
      g iam create-role --role-name "$r" --assume-role-policy-document "file://$d/trust.json" >/dev/null
    fi
    for a in $(jq -r '.[]' "$d/attached.json"); do g iam attach-role-policy --role-name "$r" --policy-arn "$a"; done
    for p in "$d"/inline.*.json; do
      [ -f "$p" ] || continue
      local pn; pn=$(basename "$p" .json); pn=${pn#inline.}
      g iam put-role-policy --role-name "$r" --policy-name "$pn" --policy-document "$(to_green < "$p" | jq -c .)"
    done
  done
  if ! g iam get-instance-profile --instance-profile-name pocketdj-stem-worker >/dev/null 2>&1; then
    g iam create-instance-profile --instance-profile-name pocketdj-stem-worker >/dev/null
  fi
  g iam get-instance-profile --instance-profile-name pocketdj-stem-worker --output json \
    | jq -e '.InstanceProfile.Roles|map(.RoleName)|index("pocketdj-stem-worker")' >/dev/null \
    || g iam add-role-to-instance-profile --instance-profile-name pocketdj-stem-worker --role-name pocketdj-stem-worker
}

# IAM users with access keys. A NEW key is minted in green and piped straight into Secrets
# Manager as pocketdj/green/<user> ({"AccessKeyId","SecretAccessKey"}); nothing is printed but
# the key id's fingerprint.
iam_users(){
  for d in "$SNAP"/iam/user-*; do
    local u; u=$(basename "$d"); u=${u#user-}
    if ! g iam get-user --user-name "$u" >/dev/null 2>&1; then
      say "create user $u"; g iam create-user --user-name "$u" >/dev/null
    fi
    for p in "$d"/inline.*.json; do
      local pn; pn=$(basename "$p" .json); pn=${pn#inline.}
      g iam put-user-policy --user-name "$u" --policy-name "$pn" --policy-document "$(to_green < "$p" | jq -c .)"
    done
    local sid="pocketdj/green/$u"
    if g secretsmanager describe-secret --secret-id "$sid" >/dev/null 2>&1; then
      say "user $u: key already stored in $sid (sha256 $(g secretsmanager get-secret-value --secret-id "$sid" --query SecretString --output text | jq -j .AccessKeyId | fp))"
      continue
    fi
    [ "$(g iam list-access-keys --user-name "$u" --query 'length(AccessKeyMetadata)')" = "0" ] \
      || die "user $u has a key but $sid is missing — rotate by hand (delete the orphan key) and re-run"
    g secretsmanager create-secret --name "$sid" --description "PocketDJ green IAM user $u access key" \
      --secret-string "{}" >/dev/null
    g iam create-access-key --user-name "$u" --output json \
      | jq -c '.AccessKey|{AccessKeyId,SecretAccessKey}' \
      | g secretsmanager put-secret-value --secret-id "$sid" --secret-string file:///dev/stdin >/dev/null
    say "user $u: new key stored in $sid (key id sha256 $(g secretsmanager get-secret-value --secret-id "$sid" --query SecretString --output text | jq -j .AccessKeyId | fp))"
  done
}

# ------------------------------------------------------------------------------------------ SQS
sqs(){
  for f in "$SNAP"/sqs/pocketdj-*-dlq.json "$SNAP"/sqs/pocketdj-stem-jobs.json "$SNAP"/sqs/pocketdj-stem-results.json \
           "$SNAP"/sqs/pocketdj-timbre-jobs.json "$SNAP"/sqs/pocketdj-timbre-results.json; do
    local q; q=$(basename "$f" .json)
    local attrs; attrs=$(to_green < "$f" | jq -c .)
    local url; url=$(g sqs get-queue-url --queue-name "$q" --query QueueUrl --output text 2>/dev/null || true)
    if [ -z "$url" ]; then
      say "create queue $q"; g sqs create-queue --queue-name "$q" --attributes "$attrs" >/dev/null
    else
      g sqs set-queue-attributes --queue-url "$url" --attributes "$attrs"
    fi
  done
}

# -------------------------------------------------------------------------------------- Secrets
# pocketdj/am-playlist-sync: value piped blue→green, never printed; fingerprints must match.
secrets(){
  local sid=pocketdj/am-playlist-sync
  if ! g secretsmanager describe-secret --secret-id "$sid" >/dev/null 2>&1; then
    say "create secret $sid (value copied from blue)"
    g secretsmanager create-secret --name "$sid" --secret-string "{}" >/dev/null
    b secretsmanager get-secret-value --secret-id "$sid" --output json | jq -j .SecretString \
      | g secretsmanager put-secret-value --secret-id "$sid" --secret-string file:///dev/stdin >/dev/null
  fi
  local gf; gf=$(g secretsmanager get-secret-value --secret-id "$sid" --output json | jq -j .SecretString | fp)
  local bf; bf=$(b secretsmanager get-secret-value --secret-id "$sid" --output json 2>/dev/null | jq -j .SecretString | fp || echo n/a)
  say "secret $sid sha256 green=$gf blue=$bf $([ "$gf" = "$bf" ] && echo MATCH || echo MISMATCH)"
}

# --------------------------------------------------------------------------------------- Lambda
lambda_env_json(){   # $1 = function; prints {"Variables":{…}} to stdout (contains the secret; pipe only)
  local fn="$1"
  local prod_dom; prod_dom=$(state_get cf.prod.domain)
  local aoss; aoss=$(state_get aoss.host)
  local env; env=$(to_green < "$SNAP/lambda/$fn.json" | jq -c '.Environment')
  [ -n "$prod_dom" ] && env=$(jq -c --arg d "$prod_dom" '.Variables |= with_entries(.value |= gsub("d2p4cubg6se03u\\.cloudfront\\.net"; $d))' <<<"$env")
  if jq -e '.Variables.AOSS_HOST' <<<"$env" >/dev/null; then
    [ -n "$aoss" ] || die "AOSS host unknown — run the aoss phase first"
    env=$(jq -c --arg h "$aoss" '.Variables.AOSS_HOST=$h' <<<"$env")
  fi
  if jq -e '.Variables.REC_ENROLL_SECRET' <<<"$env" >/dev/null; then
    # Same value as blue (shipped apps embed it). Prefer what green already has; else blue's.
    local s; s=$(g lambda get-function-configuration --function-name "$fn" --output json 2>/dev/null | jq -j '.Environment.Variables.REC_ENROLL_SECRET // empty' || true)
    [ -n "$s" ] || s=$(b lambda get-function-configuration --function-name "$fn" --output json | jq -j '.Environment.Variables.REC_ENROLL_SECRET // empty')
    [ -n "$s" ] || die "no REC_ENROLL_SECRET for $fn"
    env=$(jq -c --arg s "$s" '.Variables.REC_ENROLL_SECRET=$s' <<<"$env")
  fi
  printf '%s' "$env"
}
lambdas(){
  for f in "$SNAP"/lambda/pocketdj-*.json; do
    case "$f" in *.policy.json) continue;; esac
    local fn; fn=$(basename "$f" .json)
    local zip="$GREEN_DIR/lambda-snapshot/$fn.zip"; [ -f "$zip" ] || die "missing $zip"
    local role="arn:aws:iam::${GA}:role/$(jq -r .Role "$f")"
    if ! g lambda get-function --function-name "$fn" >/dev/null 2>&1; then
      say "create function $fn"
      local tries=0
      until lambda_env_json "$fn" | g lambda create-function --function-name "$fn" \
          --runtime "$(jq -r .Runtime "$f")" --handler "$(jq -r .Handler "$f")" --role "$role" \
          --memory-size "$(jq -r .MemorySize "$f")" --timeout "$(jq -r .Timeout "$f")" \
          --architectures "$(jq -r '.Architectures[0]' "$f")" --zip-file "fileb://$zip" \
          --environment file:///dev/stdin >/dev/null 2>"$STATE/.lambda-err"; do
        tries=$((tries+1)); [ $tries -lt 6 ] || { cat "$STATE/.lambda-err" >&2; die "create $fn failed"; }
        say "  (role propagation?) retry $tries"; sleep 10
      done
      g lambda wait function-active-v2 --function-name "$fn"
    else
      local want; want=$(openssl dgst -sha256 -binary "$zip" | base64)
      if [ "$(g lambda get-function-configuration --function-name "$fn" --query CodeSha256 --output text)" != "$want" ]; then
        say "update code $fn"
        g lambda update-function-code --function-name "$fn" --zip-file "fileb://$zip" >/dev/null
        g lambda wait function-updated-v2 --function-name "$fn"
      fi
      lambda_env_json "$fn" | g lambda update-function-configuration --function-name "$fn" \
        --memory-size "$(jq -r .MemorySize "$f")" --timeout "$(jq -r .Timeout "$f")" \
        --environment file:///dev/stdin >/dev/null
      g lambda wait function-updated-v2 --function-name "$fn"
    fi
    say "function $fn: code sha256 $(g lambda get-function-configuration --function-name "$fn" --query CodeSha256 --output text)"
  done
}
lambda_perm(){   # fn sid principal source-arn|"" [source-account]
  local fn=$1 sid=$2 pr=$3 arn=$4 acct=${5:-}
  g lambda remove-permission --function-name "$fn" --statement-id "$sid" >/dev/null 2>&1 || true
  if [ -n "$arn" ]; then
    g lambda add-permission --function-name "$fn" --statement-id "$sid" --action lambda:InvokeFunction \
      --principal "$pr" --source-arn "$arn" >/dev/null
  else
    g lambda add-permission --function-name "$fn" --statement-id "$sid" --action lambda:InvokeFunction \
      --principal "$pr" --source-account "$acct" >/dev/null
  fi
}

# ----------------------------------------------------------------------------- API Gateway (HTTP)
apis(){
  local IFS=$'\n'
  for a in $(jq -r '.[].Name' "$SNAP/apigw/apis.json"); do
    local id; id=$(g apigatewayv2 get-apis --output json | jq -r --arg n "$a" '.Items[]|select(.Name==$n)|.ApiId' | head -1)
    if [ -z "$id" ]; then
      say "create HTTP API $a"
      id=$(g apigatewayv2 create-api --name "$a" --protocol-type HTTP --query ApiId --output text)
    fi
    state_put "api.$a" "$id"
    # integrations: one per distinct function, keyed by the blue IntegrationId
    local map='{}'
    local existing; existing=$(g apigatewayv2 get-integrations --api-id "$id" --output json)
    for row in $(jq -c '.[]' "$SNAP/apigw/$a.integrations.json"); do
      local fn bid uri iid
      fn=$(jq -r .Function <<<"$row"); bid=$(jq -r .IntegrationId <<<"$row")
      uri="arn:aws:lambda:${R}:${GA}:function:$fn"
      iid=$(jq -r --arg u "$uri" '.Items[]|select(.IntegrationUri==$u)|.IntegrationId' <<<"$existing" | head -1)
      if [ -z "$iid" ]; then
        iid=$(g apigatewayv2 create-integration --api-id "$id" --integration-type AWS_PROXY \
          --integration-uri "$uri" --payload-format-version "$(jq -r .PayloadFormatVersion <<<"$row")" \
          --timeout-in-millis "$(jq -r .TimeoutInMillis <<<"$row")" --integration-method POST --query IntegrationId --output text)
      fi
      map=$(jq -c --arg b "$bid" --arg g "$iid" '.[$b]=$g' <<<"$map")
      lambda_perm "$fn" apigw-invoke apigateway.amazonaws.com "arn:aws:execute-api:${R}:${GA}:${id}/*"
    done
    local routes; routes=$(g apigatewayv2 get-routes --api-id "$id" --output json)
    for row in $(jq -c '.[]' "$SNAP/apigw/$a.routes.json"); do
      local rk tgt rid
      rk=$(jq -r .RouteKey <<<"$row")
      tgt="integrations/$(jq -r --arg b "$(jq -r '.Target|sub("integrations/";"")' <<<"$row")" '.[$b]' <<<"$map")"
      rid=$(jq -r --arg k "$rk" '.Items[]|select(.RouteKey==$k)|.RouteId' <<<"$routes" | head -1)
      if [ -z "$rid" ]; then
        g apigatewayv2 create-route --api-id "$id" --route-key "$rk" --target "$tgt" --authorization-type NONE >/dev/null
      else
        g apigatewayv2 update-route --api-id "$id" --route-id "$rid" --target "$tgt" >/dev/null
      fi
    done
    local st; st=$(jq -c '.[0]' "$SNAP/apigw/$a.stages.json")
    if ! g apigatewayv2 get-stage --api-id "$id" --stage-name '$default' >/dev/null 2>&1; then
      g apigatewayv2 create-stage --api-id "$id" --stage-name '$default' --auto-deploy >/dev/null
    fi
    g apigatewayv2 update-stage --api-id "$id" --stage-name '$default' --auto-deploy \
      --default-route-settings "$(jq -c '.DefaultRouteSettings' <<<"$st")" >/dev/null
    say "API $a: https://${id}.execute-api.${R}.amazonaws.com"
  done
}

# ---------------------------------------------------------------------------------- EventBridge
events(){
  local f="$SNAP/events/pocketdj-listening-pockets-nightly.json"
  local name; name=$(jq -r .Name "$f")
  g events put-rule --name "$name" --schedule-expression "$(jq -r .ScheduleExpression "$f")" \
    --state "$(jq -r .State "$f")" --description "$(jq -r .Description "$f")" >/dev/null
  local t; t=$(jq -c --arg a "arn:aws:lambda:${R}:${GA}:function:" '[.[]|{Id,Input,Arn:($a+.Function)}]' \
    "$SNAP/events/pocketdj-listening-pockets-nightly.targets.json")
  g events put-targets --rule "$name" --targets "$t" >/dev/null
  lambda_perm pocketdj-listening-pockets events-nightly events.amazonaws.com "arn:aws:events:${R}:${GA}:rule/$name"
  say "rule $name -> $(jq -r '.[0].Arn' <<<"$t")"
}

# ------------------------------------------------------------------------- OpenSearch Serverless
aoss(){
  "${PYTHON:-/usr/bin/python3}" "$GREEN_DIR/aoss_green.py"   # needs botocore (system python has it)
  local h; h=$(g opensearchserverless batch-get-collection --names pocketdj-search --output json \
    | jq -r '.collectionDetails[0].collectionEndpoint|sub("https://";"")')
  [ -n "$h" ] && [ "$h" != "null" ] || die "collection endpoint not ready"
  state_put aoss.host "$h"; say "AOSS host $h"
}

# ----------------------------------------------------------------------------------- CloudFront
cf_function(){
  local name=pocketdj-subpath-rewrite code="$SNAP/cf/pocketdj-subpath-rewrite.js"
  local cfg='{"Comment":"","Runtime":"cloudfront-js-2.0"}'
  if g cloudfront describe-function --name "$name" >/dev/null 2>&1; then
    local etag; etag=$(g cloudfront describe-function --name "$name" --query ETag --output text)
    g cloudfront update-function --name "$name" --if-match "$etag" --function-config "$cfg" --function-code "fileb://$code" >/dev/null
  else
    g cloudfront create-function --name "$name" --function-config "$cfg" --function-code "fileb://$code" >/dev/null
  fi
  local etag; etag=$(g cloudfront describe-function --name "$name" --query ETag --output text)
  g cloudfront publish-function --name "$name" --if-match "$etag" >/dev/null
  say "CloudFront function $name published (LIVE)"
}
cf_oacs(){
  local IFS=$'\n'
  for row in $(jq -c '.[]' "$SNAP/cf/oac.json"); do
    local n; n=$(jq -r .Name <<<"$row")
    local id; id=$(g cloudfront list-origin-access-controls --output json | jq -r --arg n "$n" '.OriginAccessControlList.Items[]?|select(.Name==$n)|.Id')
    if [ -z "$id" ]; then
      id=$(g cloudfront create-origin-access-control --origin-access-control-config \
        "$(jq -c '{Name,Description,SigningProtocol,SigningBehavior,OriginAccessControlOriginType}' <<<"$row")" \
        --query OriginAccessControl.Id --output text)
    fi
    state_put "oac.$(jq -r .Id <<<"$row")" "$id"
  done
}
# key -> blue distribution id
CF_KEYS="dev:E123GKAO9JVETP prod:E1SP8M1SIF7Q8D legal:E9XDXX3A506H6 www:E9L9V188S55F7 jukebox:E1XIWBBPFOJ07E"
cf_desired(){   # $1 key, $2 blue id -> green DistributionConfig on stdout
  local key=$1 bid=$2
  local IFS=$'\n'
  local search_id; search_id=$(state_get api.pocketdj-search)
  [ -n "$search_id" ] || die "green search API unknown — run apis first"
  local cfg; cfg=$(to_green < "$SNAP/cf/$bid.json" | sed -e "s/fnlg100ir5\.execute-api/${search_id}.execute-api/g")
  for row in $(jq -c '.[]' "$SNAP/cf/oac.json"); do
    local bo go; bo=$(jq -r .Id <<<"$row"); go=$(state_get "oac.$bo")
    cfg=$(sed -e "s/\"$bo\"/\"$go\"/g" <<<"$cfg")
  done
  jq -c --arg ref "pocketdj-green-$key" '
      .CallerReference=$ref
    | .Comment=(.Comment+" [green]")
    | .Aliases={"Quantity":0}
    | .ViewerCertificate={"CloudFrontDefaultCertificate":true,"MinimumProtocolVersion":"TLSv1","SSLSupportMethod":"vip","CertificateSource":"cloudfront"}' <<<"$cfg"
}
cf_dists(){
  for kv in $CF_KEYS; do
    local key=${kv%%:*} bid=${kv#*:}
    local want; want=$(cf_desired "$key" "$bid")
    local comment; comment=$(jq -r .Comment <<<"$want")
    local id; id=$(cf_id_by_comment "$comment")
    if [ -z "$id" ]; then
      say "create distribution $key ($comment)"
      id=$(g cloudfront create-distribution --distribution-config "$want" --query Distribution.Id --output text)
    else
      local cur etag; cur=$(g cloudfront get-distribution-config --id "$id" --output json)
      etag=$(jq -r .ETag <<<"$cur")
      # Keep anything green-side that cutover adds (aliases + ACM cert) — never strip them on re-run.
      want=$(jq -c --argjson c "$(jq -c .DistributionConfig <<<"$cur")" \
        '.CallerReference=$c.CallerReference
         | if ($c.Aliases.Quantity//0)>0 then .Aliases=$c.Aliases | .ViewerCertificate=$c.ViewerCertificate else . end' <<<"$want")
      if [ "$(jq -S . <<<"$want")" != "$(jq -S .DistributionConfig <<<"$cur")" ]; then
        say "update distribution $key ($id)"
        g cloudfront update-distribution --id "$id" --if-match "$etag" --distribution-config "$want" >/dev/null
      fi
    fi
    state_put "cf.$key.id" "$id"; state_put "cf.$key.domain" "$(cf_domain "$id")"
    say "distribution $key: $id $(state_get "cf.$key.domain")"
  done
}

# -------------------------------------------------------------------------------------------- ACM
# Certs for the future aliases, in us-east-1, DNS-validated. Their validation CNAMEs go into the
# GREEN zone, so they validate only after the Hover nameserver switch (expected).
ACM_CERTS="app.pocket-dj.com dev.app.pocket-dj.com legal.pocket-dj.com jukebox.pocket-dj.com pocket-dj.com"
acm(){
  local zid; zid=$(state_get r53.zone)
  for dn in $ACM_CERTS; do
    local arn; arn=$(g1 acm list-certificates --certificate-statuses PENDING_VALIDATION ISSUED --output json \
      | jq -r --arg d "$dn" '.CertificateSummaryList[]|select(.DomainName==$d)|.CertificateArn' | head -1)
    if [ -z "$arn" ]; then
      local extra=(); [ "$dn" = "pocket-dj.com" ] && extra=(--subject-alternative-names www.pocket-dj.com)
      arn=$(g1 acm request-certificate --domain-name "$dn" "${extra[@]}" --validation-method DNS \
        --idempotency-token "$(echo "$dn" | tr -dc 'a-z0-9' | cut -c1-30)" --query CertificateArn --output text)
      say "requested cert $dn"; sleep 8
    fi
    state_put "acm.$dn" "$arn"
    [ -n "$zid" ] || continue
    local recs; recs=$(g1 acm describe-certificate --certificate-arn "$arn" --output json \
      | jq -c '[.Certificate.DomainValidationOptions[].ResourceRecord|select(.!=null)]|unique')
    while IFS= read -r rr; do
      g route53 change-resource-record-sets --hosted-zone-id "$zid" --change-batch "$(jq -c '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:.Name,Type:.Type,TTL:300,ResourceRecords:[{Value:.Value}]}}]}' <<<"$rr")" >/dev/null
      say "  validation CNAME $(jq -r .Name <<<"$rr") -> green zone"
    done < <(jq -c '.[]' <<<"$recs")
  done
}

# -------------------------------------------------------------------------------------- Route 53
# EXACT mirror of blue's records (except the zone's own apex NS/SOA), still pointing at BLUE
# targets, so the Hover nameserver switch changes nothing by itself.
r53(){
  local zid; zid=$(state_get r53.zone)
  if [ -z "$zid" ]; then
    zid=$(g route53 list-hosted-zones-by-name --dns-name pocket-dj.com --output json \
      | jq -r '.HostedZones[]|select(.Name=="pocket-dj.com.")|.Id' | head -1)
  fi
  if [ -z "$zid" ]; then
    zid=$(g route53 create-hosted-zone --name pocket-dj.com --caller-reference pocketdj-green-zone-1 \
      --hosted-zone-config "{\"Comment\":\"PocketDJ primary zone (green, account ${GA}) - mirror of blue until cutover\"}" \
      --query HostedZone.Id --output text)
    say "created zone $zid"
  fi
  zid=${zid#/hostedzone/}; state_put r53.zone "$zid"
  local changes; changes=$(jq -c '[.[]|select((.Name=="pocket-dj.com." and (.Type=="NS" or .Type=="SOA"))|not)
      |{Action:"UPSERT",ResourceRecordSet:.}]' "$SNAP/r53/rrsets.json")
  local cid; cid=$(g route53 change-resource-record-sets --hosted-zone-id "$zid" \
    --change-batch "{\"Comment\":\"mirror of blue\",\"Changes\":$changes}" --query ChangeInfo.Id --output text)
  g route53 wait resource-record-sets-changed --id "$cid"
  g route53 get-hosted-zone --id "$zid" --output json | jq -r '.DelegationSet.NameServers[]' > "$STATE/r53.nameservers"
  say "zone $zid mirrored ($(jq length <<<"$changes") rrsets); NS: $(tr '\n' ' ' < "$STATE/r53.nameservers")"
}

# -------------------------------------------------------------------------------------------- SES
# Domain identity (Easy DKIM, new green tokens — published only at cutover) + the receipt rule set
# pocketdj-inbound, created INACTIVE: one active rule set per account+region, and activating it is
# a cutover step (it must also carry any other domain's rules living in this account).
ses(){
  if ! g sesv2 get-email-identity --email-identity pocket-dj.com >/dev/null 2>&1; then
    g sesv2 create-email-identity --email-identity pocket-dj.com >/dev/null; say "SES identity pocket-dj.com created"
  fi
  g sesv2 get-email-identity --email-identity pocket-dj.com --output json \
    | jq '{VerificationStatus,Dkim:{Status:.DkimAttributes.Status,Tokens:.DkimAttributes.Tokens}}' > "$STATE/ses.identity.json"
  lambda_perm pocketdj-mail-forwarder ses-invoke ses.amazonaws.com "" "$GA"
  if ! g ses describe-receipt-rule-set --rule-set-name pocketdj-inbound >/dev/null 2>&1; then
    g ses create-receipt-rule-set --rule-set-name pocketdj-inbound
  fi
  while IFS= read -r rule; do
    local n; n=$(jq -r .Name <<<"$rule")
    if g ses describe-receipt-rule --rule-set-name pocketdj-inbound --rule-name "$n" >/dev/null 2>&1; then
      g ses update-receipt-rule --rule-set-name pocketdj-inbound --rule "$rule"
    else
      g ses create-receipt-rule --rule-set-name pocketdj-inbound --rule "$rule"
    fi
    say "SES rule pocketdj-inbound/$n (rule set left INACTIVE until cutover)"
  done < <(to_green < "$SNAP/ses/pocketdj-rules.json" | jq -c '.[]')
}

# -------------------------------------------------------------------------------------------- EC2
ec2(){
  local vpc; vpc=$(g ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
  local sgf="$SNAP/ec2/pocketdj-stem-sg.json"
  local sg; sg=$(g ec2 describe-security-groups --filters Name=group-name,Values=pocketdj-stem-sg Name=vpc-id,Values="$vpc" --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$sg" = "None" ] || [ -z "$sg" ]; then
    sg=$(g ec2 create-security-group --group-name pocketdj-stem-sg --description "$(jq -r .Description "$sgf")" --vpc-id "$vpc" --query GroupId --output text)
    g ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions "$(jq -c '[.IpPermissions[]|del(.UserIdGroupPairs)]' "$sgf")" >/dev/null
  fi
  state_put ec2.sg "$sg"
  # Key pair: the operator's existing public key (no new private key to store anywhere).
  if ! g ec2 describe-key-pairs --key-names pocketdj-stem-key >/dev/null 2>&1; then
    g ec2 import-key-pair --key-name pocketdj-stem-key --public-key-material "fileb://$HOME/.ssh/id_ed25519.pub" >/dev/null
  fi
  # stem worker: blue's golden AMI is PRIVATE to blue and cannot be launched here. The green
  # template points at a stock Ubuntu 22.04 x86 AMI as a PLACEHOLDER; see docs/aws-green-cutover.md
  # ("Stem golden AMI"). A worker booted from it finds no node/venv and terminates itself.
  local ubuntu; ubuntu=$(g ssm get-parameter --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id --query Parameter.Value --output text)
  local golden; golden=$(state_get ec2.stem.golden-ami); [ -n "$golden" ] && ubuntu="$golden"
  for t in pocketdj-stem-worker pocketdj-timbre-worker; do
    local ud; ud=$(to_green < "$SNAP/ec2/$t.userdata.sh" | base64)
    local data; data=$(to_green < "$SNAP/ec2/$t.json" | jq -c --arg ud "$ud" --arg sg "$sg" '.UserData=$ud
      | if .SecurityGroupIds then .SecurityGroupIds=[$sg] else . end
      | if .NetworkInterfaces then .NetworkInterfaces|=map(.Groups=[$sg]) else . end')
    if [ "$t" = pocketdj-stem-worker ]; then data=$(jq -c --arg a "$ubuntu" '.ImageId=$a' <<<"$data"); fi
    if jq -e '.NetworkInterfaces[0].SubnetId' <<<"$data" >/dev/null 2>&1; then
      local bsub az gsub; bsub=$(jq -r '.NetworkInterfaces[0].SubnetId' <<<"$data")
      az=$(jq -r --arg s "$bsub" '.[]|select(.SubnetId==$s)|.AvailabilityZone' "$SNAP/ec2/subnets.json")
      gsub=$(g ec2 describe-subnets --filters Name=vpc-id,Values="$vpc" Name=availability-zone,Values="$az" --query 'Subnets[0].SubnetId' --output text)
      data=$(jq -c --arg s "$gsub" '.NetworkInterfaces|=map(.SubnetId=$s)' <<<"$data")
    fi
    if g ec2 describe-launch-templates --launch-template-names "$t" >/dev/null 2>&1; then
      local cur; cur=$(g ec2 describe-launch-template-versions --launch-template-name "$t" --versions '$Default' --output json | jq -c '.LaunchTemplateVersions[0].LaunchTemplateData')
      if [ "$(jq -S . <<<"$cur")" != "$(jq -S . <<<"$data")" ]; then
        local v; v=$(g ec2 create-launch-template-version --launch-template-name "$t" --launch-template-data "$data" --query LaunchTemplateVersion.VersionNumber --output text)
        g ec2 modify-launch-template --launch-template-name "$t" --default-version "$v" >/dev/null
        say "launch template $t -> v$v"
      fi
    else
      g ec2 create-launch-template --launch-template-name "$t" --launch-template-data "$data" >/dev/null
      say "launch template $t created"
    fi
  done
}

# ------------------------------------------------------------------------------------------ main
run(){
  case "$1" in
    s3) s3_buckets; s3_policies; s3_logging ;;
    s3-policies) s3_policies ;;
    iam) iam_roles; iam_users ;;
    sqs) sqs ;;
    secrets) secrets ;;
    aoss) aoss ;;
    lambda) lambdas ;;
    apis) apis ;;
    events) events ;;
    cf) cf_function; cf_oacs; cf_dists ;;
    r53) r53 ;;
    acm) acm ;;
    ses) ses ;;
    ec2) ec2 ;;
    all) for p in s3 iam sqs secrets aoss lambda apis events cf s3-policies lambda r53 acm ses ec2; do run "$p"; done ;;
    *) die "unknown phase $1" ;;
  esac
}
[ $# -gt 0 ] || set -- all
g sts get-caller-identity --query Account --output text | grep -qx "$GA" || die "profile $GREEN_PROFILE is not account $GA"
for p in "$@"; do say "=== phase $p"; run "$p"; done
say "done"
