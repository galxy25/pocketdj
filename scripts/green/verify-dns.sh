#!/usr/bin/env bash
# Verify the GREEN pocket-dj.com zone answers exactly like BLUE, record by record, by asking each
# zone's authoritative nameservers directly (works before the Hover nameserver switch).
#   bash scripts/green/verify-dns.sh            # markdown table on stdout; exit 1 on any mismatch
# Alias A records to CloudFront return edge IPs that can rotate between queries, so for those the
# check also accepts "same answer set modulo ordering on a re-query" and reports the resolved
# CloudFront target. Green-only extras (ACM validation CNAMEs) are listed separately.
. "$(dirname "$0")/lib.sh"
BNS=$(jq -r '.NameServers[0]' "$SNAP/r53/zone.json")
GNS=$(cat "$STATE/r53.nameservers")
q(){ dig +short +norecurse "@$1" "$2" "$3" | sort | tr '\n' ' ' | sed 's/ $//'; }
fail=0
echo "| name | type | blue (@$BNS) | green NS results | match |"
echo "|---|---|---|---|---|"
while IFS=$'\t' read -r name type; do
  bv=$(q "$BNS" "$name" "$type")
  res=""; ok=1
  for ns in $GNS; do
    gv=$(q "$ns" "$name" "$type")
    if [ "$gv" != "$bv" ]; then
      # alias A to CloudFront: re-query blue once (edge IP sets rotate)
      bv2=$(q "$BNS" "$name" "$type"); gv2=$(q "$ns" "$name" "$type")
      [ "$gv2" = "$bv2" ] || ok=0
    fi
    res="$res ${ns%%.*}=$([ "$gv" = "$bv" ] && echo same || echo "$gv")"
  done
  [ $ok = 1 ] || fail=1
  short=$(cut -c1-60 <<<"$bv")
  echo "| $name | $type | $short | $res | $([ $ok = 1 ] && echo YES || echo NO) |"
done < <(jq -r '.[]|select((.Name=="pocket-dj.com." and (.Type=="NS" or .Type=="SOA"))|not)|[.Name,.Type]|@tsv' "$SNAP/r53/rrsets.json")
echo
echo "Green-only records (not in blue):"
zid=$(state_get r53.zone)
g route53 list-resource-record-sets --hosted-zone-id "$zid" --output json \
  | jq -r --slurpfile b "$SNAP/r53/rrsets.json" '.ResourceRecordSets[] as $r
      | select(($b[0]|map(select(.Name==$r.Name and .Type==$r.Type))|length)==0)
      | "- \($r.Name) \($r.Type) \($r.ResourceRecords[0].Value // $r.AliasTarget.DNSName)"'
exit $fail
