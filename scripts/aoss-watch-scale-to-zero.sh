#!/usr/bin/env bash
# Watch whether the parallel pocketdj-sz collection actually SCALES TO ZERO when idle.
#
# Clean signal: once a collection GROUP exists, AOSS emits SearchOCU / IndexingOCU
# dimensioned by CollectionGroupName — so we read the NEW group's OCU directly
# (no need to disentangle it from the old pocketdj-search's constant 0.5+0.5 floor,
# which shows only on the account-level ClientId-dimensioned metric).
#
# Scale-to-zero (per AWS docs) kicks in ~10 min after the last request to the group;
# expect groupS and groupI to fall to 0 within ~15 min of the last A/B query.
#
# Runs a bounded poll loop (default every 5 min for up to 2 h), appending a
# timestamped line to a log. Designed to run in the background.
#
# Usage: bash scripts/aoss-watch-scale-to-zero.sh [intervalSec] [maxMinutes]
set -uo pipefail
export AWS_PROFILE="${AWS_PROFILE:-levi}"
REGION="${AWS_REGION:-us-west-2}"
INTERVAL="${1:-300}"        # 5 min
MAX_MIN="${2:-120}"         # 2 h
GROUP="pocketdj-sz-grp"
GROUPID="$(aws opensearchserverless batch-get-collection-group --names "$GROUP" --region "$REGION" 2>/dev/null | python3 -c "import sys,json;g=json.load(sys.stdin).get('collectionGroupDetails',[]);print(g[0]['id'] if g else '')")"
LOG="$(dirname "$0")/../.aoss-sz-watch.log"

now_utc() { date -u +%FT%TZ; }
ago_utc() { date -u -v-"$1"M +%FT%TZ 2>/dev/null || date -u -d "$1 min ago" +%FT%TZ; }

# latest datapoint of the GROUP-scoped OCU metric over the last 20 min (period 60s)
group_ocu() { # $1 = SearchOCU|IndexingOCU
  aws cloudwatch get-metric-statistics --namespace AWS/AOSS --metric-name "$1" \
    --dimensions Name=CollectionGroupId,Value="$GROUPID" Name=CollectionGroupName,Value="$GROUP" Name=ClientId,Value=011183829623 \
    --start-time "$(ago_utc 20)" --end-time "$(now_utc)" --period 60 --statistics Average --region "$REGION" 2>/dev/null \
    | python3 -c "import sys,json;p=sorted(json.load(sys.stdin).get('Datapoints',[]),key=lambda x:x['Timestamp']);print(f\"{p[-1]['Average']:.3f}\" if p else '0.000')"
}
acct_ocu() { # account-level (old collection floor) for context
  aws cloudwatch get-metric-statistics --namespace AWS/AOSS --metric-name "$1" \
    --dimensions Name=ClientId,Value=011183829623 \
    --start-time "$(ago_utc 20)" --end-time "$(now_utc)" --period 60 --statistics Average --region "$REGION" 2>/dev/null \
    | python3 -c "import sys,json;p=sorted(json.load(sys.stdin).get('Datapoints',[]),key=lambda x:x['Timestamp']);print(f\"{p[-1]['Average']:.3f}\" if p else 'nan')"
}

echo "[watch] group=$GROUP id=$GROUPID  interval=${INTERVAL}s  max=${MAX_MIN}min  started $(now_utc)" | tee -a "$LOG"
echo "[watch] time                 groupS groupI | acctS acctI | verdict" | tee -a "$LOG"
ticks=$(( MAX_MIN * 60 / INTERVAL ))
zero_streak=0
for t in $(seq 0 "$ticks"); do
  GS="$(group_ocu SearchOCU)"; GI="$(group_ocu IndexingOCU)"
  AS="$(acct_ocu SearchOCU)"; AI="$(acct_ocu IndexingOCU)"
  if python3 -c "import sys;sys.exit(0 if float('$GS')<0.05 and float('$GI')<0.05 else 1)" 2>/dev/null; then
    V="SCALED-TO-ZERO"; zero_streak=$((zero_streak+1))
  else V="warm"; zero_streak=0; fi
  printf "[watch] %s  %5s  %5s | %5s %5s | %s (streak=%d)\n" "$(now_utc)" "$GS" "$GI" "$AS" "$AI" "$V" "$zero_streak" | tee -a "$LOG"
  if [ "$zero_streak" -ge 2 ]; then
    echo "[watch] ✅ CONFIRMED: pocketdj-sz-grp scaled to zero (2 consecutive idle ticks, groupS≈0 & groupI≈0)." | tee -a "$LOG"
    echo "[watch] Meanwhile old pocketdj-search holds acctS/acctI≈0.5 — that is the ~\$70-175/mo floor scale-to-zero removes." | tee -a "$LOG"
    exit 0
  fi
  [ "$t" -lt "$ticks" ] && sleep "$INTERVAL"
done
echo "[watch] ⏱ ${MAX_MIN}min window ended without a 2-tick zero streak — inspect $LOG" | tee -a "$LOG"
