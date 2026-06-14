#!/usr/bin/env bash
# METADATA BACKFILL runner — recover the "unmatched" albums the first metadata pass
# couldn't match, by searching the web in a REAL browser (Chrome via Playwright, typing
# into the search box like a person) across Google -> DuckDuckGo -> Bing. Runs as
# PARALLEL SHARDS (each its own Chrome profile + disjoint slice) so it isn't crawling
# one album at a time, and re-invokes each shard until its slice is exhausted (albums
# deferred because the local model was reloading get retried automatically).
#
# Optionally finishes with a single SAFARI sweep (AppleScript, a real non-headless
# browser) over whatever's still unmatched — set SAFARI=1.
#
#   scripts/run-backfill.sh
#   SHARDS=4 ENGINES=google,duckduckgo,bing scripts/run-backfill.sh
#   SAFARI=1 scripts/run-backfill.sh            # add the Safari straggler sweep
#
# Output: index-out/shards-pw/google.jsonl (folded into the final index by the merge
# step — manifest.mjs reads google.jsonl LAST so a recovered, matched-with-tracks
# record supersedes the trackless "unmatched" pass-through).
set -uo pipefail
cd "$(dirname "$0")/.."

LIB=.claude/skills/analog-indexer/lib
DIR=${DIR:-index-out/shards-pw}
META="$DIR/enriched.jsonl"
OUT="$DIR/google.jsonl"
PROG=${PROG:-index-out/backfill-progress.log}
SHARDS=${SHARDS:-3}
ENGINES=${ENGINES:-google,duckduckgo,bing}
DELAY=${DELAY:-2500}
SAFARI=${SAFARI:-0}
MAX_ROUNDS=${MAX_ROUNDS:-30}   # per-shard re-invocation cap (deferred-album retries)

count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
unmatched_count() {
  node -e 'const fs=require("fs");let n=0;for(const l of fs.readFileSync(process.argv[1],"utf8").split("\n")){if(!l.trim())continue;try{if(JSON.parse(l).status==="unmatched")n++}catch{}}console.log(n)' "$1"
}

TOTAL=$(unmatched_count "$META")
echo "backfill: $TOTAL unmatched albums across $SHARDS chrome shards · engines=$ENGINES"
[ "$TOTAL" -eq 0 ] && { echo "nothing unmatched — done"; exit 0; }

per=$(( (TOTAL + SHARDS - 1) / SHARDS ))

# One shard: re-invoke the resumable scraper over its slice until the slice is fully
# attempted (deferred/model-unavailable albums aren't written, so they re-run) or we
# stop making progress for two rounds (model down for good / genuine dead ends).
shard() {
  local k=$1 a=$2 b=$3
  local out="$DIR/google.part$k.jsonl"
  local want=$(( b > TOTAL ? TOTAL - a : b - a ))
  local last=-1 stuck=0 round=0
  while [ "$round" -lt "$MAX_ROUNDS" ]; do
    node "$LIB/enrich-google.mjs" --in "$META" --out "$out" \
      --slice "$a:$b" --browser chrome --fallback-browser none \
      --engines "$ENGINES" --profile-dir "/tmp/pocketdj-google-profile-$k" \
      --delay "$DELAY" --progress-file "$PROG" >>"/tmp/pocketdj-backfill-$k.log" 2>&1 || true
    local done; done=$(count "$out")
    [ "$done" -ge "$want" ] && break
    if [ "$done" -le "$last" ]; then stuck=$((stuck+1)); else stuck=0; fi
    [ "$stuck" -ge 2 ] && { echo "[shard $k] no progress ($done/$want) — stopping"; break; }
    last=$done; round=$((round+1)); sleep 15
  done
  echo "[shard $k] $(count "$out")/$want attempted"
}

pids=()
for k in $(seq 0 $((SHARDS-1))); do
  a=$(( k * per )); b=$(( a + per ))
  shard "$k" "$a" "$b" &
  pids+=($!)
  sleep 3   # stagger Chrome launches
done
wait "${pids[@]}"

# Merge shard parts -> google.jsonl (each candidateIndex lives in exactly one shard).
: > "$OUT"
for k in $(seq 0 $((SHARDS-1))); do
  [ -f "$DIR/google.part$k.jsonl" ] && cat "$DIR/google.part$k.jsonl" >> "$OUT"
done
echo "chrome pass merged -> $OUT ($(count "$OUT") attempted)"

# Optional relentless SAFARI sweep over whatever's STILL unmatched.
if [ "$SAFARI" = "1" ]; then
  STILL="/tmp/pocketdj-still-unmatched.jsonl"
  node -e '
    const fs=require("fs");
    const lines=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);
    const out=[];
    for(const l of lines){try{const a=JSON.parse(l);if(a.status==="unmatched")out.push(l)}catch{}}
    fs.writeFileSync(process.argv[2], out.join("\n")+(out.length?"\n":""));
    console.log(out.length);
  ' "$OUT" "$STILL" | { read n; echo "safari sweep: $n still unmatched"; }
  if [ -s "$STILL" ]; then
    node "$LIB/enrich-google.mjs" --in "$STILL" --out "$DIR/google.safari.jsonl" \
      --browser safari --fallback-browser none --engines "$ENGINES" \
      --delay "$DELAY" --progress-file "$PROG" >>/tmp/pocketdj-backfill-safari.log 2>&1 || true
    # Safari recoveries appended LAST so a matched record supersedes the chrome miss.
    [ -f "$DIR/google.safari.jsonl" ] && cat "$DIR/google.safari.jsonl" >> "$OUT"
    echo "safari pass merged -> $OUT"
  fi
fi

RECOVERED=$(node -e 'const fs=require("fs");let n=0;for(const l of fs.readFileSync(process.argv[1],"utf8").split("\n")){if(!l.trim())continue;try{if(JSON.parse(l).status==="matched")n++}catch{}}console.log(n)' "$OUT")
echo "backfill complete: recovered $RECOVERED / $TOTAL -> $OUT"
