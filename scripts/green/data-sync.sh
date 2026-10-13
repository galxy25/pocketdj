#!/usr/bin/env bash
# Copy blue bucket contents -> green buckets, server-side (S3 CopyObject; no local download).
# Blue is only READ (it is the copy source). Runs as blue's Developer user (profile levi), which the
# GREEN buckets temporarily allow via `GRANT=1 bash scripts/green/provision.sh s3-policies`.
# Objects land owned by green (BucketOwnerEnforced).
#
#   bash scripts/green/data-sync.sh [bucket-suffix …]     # default: all, rips last
#   LOG_DIR=… to choose where per-bucket logs go (default scripts/green/state/sync-logs, untracked)
#
# Re-runnable: `aws s3 sync` only copies new/changed keys. It never deletes in green
# (no --delete) unless SYNC_DELETE=1 (use at the final cutover re-sync so green == blue).
# After each bucket, verify.sh-style counts/bytes are compared and written to the log.
. "$(dirname "$0")/lib.sh"
LOG_DIR="${LOG_DIR:-$STATE/sync-logs}"; mkdir -p "$LOG_DIR"
[ $# -gt 0 ] || set -- am-sync-jobs dev-web legal-site logs mail prod-web rec www rips
DEL=(); [ "${SYNC_DELETE:-0}" = "1" ] && DEL=(--delete)

count(){   # profile bucket -> "objects bytes"
  aws --profile "$1" --region "$R" s3api list-objects-v2 --bucket "$2" --output json \
    --query '{n:length(Contents||`[]`),b:sum(Contents[].Size||`[0]`)}' | jq -r '"\(.n) \(.b)"'
}

for n in "$@"; do
  src=$(bbucket "$n"); dst=$(gbucket "$n"); log="$LOG_DIR/$n.log"
  say "sync $src -> $dst  (log $log)"
  {
    echo "=== $(date -u +%FT%TZ) start"
    aws --profile "$BLUE_PROFILE" --region "$R" s3 sync "s3://$src" "s3://$dst" \
      --only-show-errors --no-progress "${DEL[@]}"
    echo "=== $(date -u +%FT%TZ) sync exit $?"
    bc=$(count "$BLUE_PROFILE" "$src"); gc=$(count "$GREEN_PROFILE" "$dst")
    echo "blue  $src $bc"
    echo "green $dst $gc"
    [ "$bc" = "$gc" ] && echo "VERIFY MATCH" || echo "VERIFY DIFF (blue may still be receiving writes)"
  } >> "$log" 2>&1
  tail -3 "$log" >&2
done
say "data-sync finished"
