#!/usr/bin/env bash
# Smoke-test GREEN on its raw endpoints (*.cloudfront.net, execute-api ids). Touches only green.
#   bash scripts/green/smoke.sh [cf search rec pockets amsync sqs ec2 ses]   (default: all)
# Secrets (enroll secret, djpocketsearch key) are read from green and handed to curl/node via
# stdin/env — never printed.
. "$(dirname "$0")/lib.sh"
PASS=0; FAIL=0
ok(){ say "PASS  $*"; PASS=$((PASS+1)); }
ko(){ say "FAIL  $*"; FAIL=$((FAIL+1)); }
api(){ echo "https://$(state_get "api.$1").execute-api.${R}.amazonaws.com"; }
cfd(){ echo "https://$(state_get "cf.$1.domain")"; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }

t_cf(){
  for k in prod dev; do
    local b; b=$(cfd "$k")
    [ "$(code "$b/")" = 200 ] && ok "cf $k / ($b)" || ko "cf $k / -> $(code "$b/")"
    local n; n=$(curl -s "$b/current-index.json" | jq -r '(.albums // .items // [])|length' 2>/dev/null || echo err)
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] && ok "cf $k current-index.json ($n albums)" || ko "cf $k current-index.json -> $n"
    [ "$(code "$b/some/spa/route")" = 200 ] && ok "cf $k SPA fallback" || ko "cf $k SPA fallback"
  done
  local l; l=$(cfd legal); [ "$(code "$l/")" = 200 ] && ok "cf legal / ($l)" || ko "cf legal / -> $(code "$l/")"
  local w; w=$(cfd www);   [ "$(code "$w/")" = 200 ] && ok "cf www / ($w)" || ko "cf www / -> $(code "$w/")"
  # jukebox / is 404 on blue too (no root page); the AASA file is what must serve.
  local j; j=$(cfd jukebox); local jc; jc=$(code "$j/.well-known/apple-app-site-association")
  [ "$jc" = 200 ] && ok "cf jukebox AASA ($j)" || ko "cf jukebox AASA -> $jc"
  # rips: public object straight from the green bucket
  local key; key=$(g s3api list-objects-v2 --bucket "$(gbucket rips)" --prefix rips/ --max-items 1 --output json | jq -r '.Contents[0].Key // empty')
  if [ -n "$key" ]; then
    [ "$(code -r 0-1023 "https://$(gbucket rips).s3.${R}.amazonaws.com/$key")" = 206 ] && ok "rips public range GET ($key)" || ko "rips public GET $key"
  else ko "rips: no objects yet"; fi
}

t_search(){
  local creds; creds=$(g secretsmanager get-secret-value --secret-id pocketdj/green/djpocketsearch --query SecretString --output text)
  local host; host=$(state_get aoss.host)
  for base in "$(api pocketdj-search)" "$(cfd prod)"; do
    if AK=$(jq -r .AccessKeyId <<<"$creds") SK=$(jq -r .SecretAccessKey <<<"$creds") \
        node "$GREEN_DIR/smoke-search.mjs" "$host" "$base" love >&2; then ok "search via $base"; else ko "search via $base"; fi
  done
}

enroll_hdr(){ g lambda get-function-configuration --function-name pocketdj-rec-engine --output json \
  | jq -r '"x-pocketdj-enroll: " + .Environment.Variables.REC_ENROLL_SECRET'; }

t_rec(){
  local b; b=$(api pocketdj-rec-engine)
  local h; h=$(curl -s "$b/health"); jq -e '.ok==true' <<<"$h" >/dev/null && ok "rec /health $h" || ko "rec /health $h"
  local prof="greensmoke-$(openssl rand -hex 6)" key; key=$(openssl rand -hex 16)
  local now; now=$(($(date +%s)*1000))
  local body; body="{\"activity\":[{\"id\":\"smoke-1\",\"atMs\":$now,\"kind\":\"play\",\"itemId\":\"sng_smoke\"}]}"
  local r; r=$(enroll_hdr | curl -s -w ' %{http_code}' -X POST "$b/events" -H @- -H "x-pocketdj-profile: $prof" \
    -H "authorization: Bearer $key" -H 'content-type: application/json' -d "$body")
  [ "${r##* }" = 200 ] && ok "rec enroll POST /events ($prof) ${r% *}" || ko "rec POST /events -> $r"
  r=$(curl -s -w ' %{http_code}' "$b/recs/songs?limit=5" -H "x-pocketdj-profile: $prof" -H "authorization: Bearer $key")
  [ "${r##* }" = 200 ] && ok "rec GET /recs/songs $(cut -c1-120 <<<"${r% *}")" || ko "rec GET /recs/songs -> $r"
  r=$(curl -s -w ' %{http_code}' "$b/recs/songs?limit=5" -H "x-pocketdj-profile: $prof" -H "authorization: Bearer wrong$key")
  [ "${r##* }" = 403 ] && ok "rec wrong key -> 403" || ko "rec wrong key -> $r"
  r=$(curl -s -w ' %{http_code}' -X DELETE "$b/state" -H "x-pocketdj-profile: $prof" -H "authorization: Bearer $key")
  [ "${r:(-3)}" = 200 ] && ok "rec DELETE /state ${r% *}" || ko "rec DELETE /state -> $r"
  local left; left=$(g s3api list-objects-v2 --bucket "$(gbucket rec)" --prefix rec/ --output json | jq '[.Contents[]?|select(.Key|test("state/"))]|length')
  say "  rec bucket state objects after delete: $left (copied blue profiles + 0 smoke)"
}

t_pockets(){
  local b; b=$(api pocketdj-rec-engine)
  local h; h=$(curl -s "$b/pockets/health"); jq -e '.ok==true' <<<"$h" >/dev/null && ok "pockets /pockets/health $h" || ko "pockets /pockets/health $h"
}

t_amsync(){
  local h; h=$(curl -s "$(api pocketdj-am-playlist-sync)/health"); jq -e '.ok==true' <<<"$h" >/dev/null && ok "am-playlist-sync /health $h" || ko "am-playlist-sync /health $h"
}

t_sqs(){
  local q; q=$(g sqs get-queue-url --queue-name pocketdj-stem-results --query QueueUrl --output text)
  local m="green-smoke-$(openssl rand -hex 4)"
  g sqs send-message --queue-url "$q" --message-body "$m" >/dev/null
  local got; got=$(g sqs receive-message --queue-url "$q" --wait-time-seconds 10 --output json | jq -r '.Messages[0].Body // empty')
  [ "$got" = "$m" ] && ok "sqs send/receive on pocketdj-stem-results" || ko "sqs got '$got'"
  g sqs purge-queue --queue-url "$q"
  local dlq; dlq=$(g sqs get-queue-attributes --queue-url "$(g sqs get-queue-url --queue-name pocketdj-stem-jobs --query QueueUrl --output text)" --attribute-names RedrivePolicy --output json | jq -r '.Attributes.RedrivePolicy|fromjson|.deadLetterTargetArn')
  [ "$dlq" = "arn:aws:sqs:${R}:${GA}:pocketdj-stem-jobs-dlq" ] && ok "stem-jobs redrive -> $dlq" || ko "redrive $dlq"
}

t_ec2(){
  for t in pocketdj-stem-worker pocketdj-timbre-worker; do
    local out; out=$(g ec2 run-instances --launch-template "LaunchTemplateName=$t" --dry-run 2>&1 || true)
    if grep -q DryRunOperation <<<"$out"; then ok "launch template $t validates (dry-run)"; else ko "launch template $t: $(tail -1 <<<"$out")"; fi
  done
  local n; n=$(g ec2 describe-instances --filters Name=instance-state-name,Values=pending,running --query 'length(Reservations)' --output text)
  [ "$n" = 0 ] && ok "no running instances" || ko "$n running instances"
}

t_ses(){ say "SES identity: $(jq -c . "$STATE/ses.identity.json")"; }

[ $# -gt 0 ] || set -- cf search rec pockets amsync sqs ec2 ses
for t in "$@"; do "t_$t"; done
say "smoke: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
