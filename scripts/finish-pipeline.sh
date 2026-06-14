#!/usr/bin/env bash
# Watches the streaming indexer pipeline and, once it finishes, merges the final
# manifest into index.json and REDEPLOYS dev + prod with the full real catalog.
# Runs detached (hours); writes a running summary to index-out/PIPELINE_STATUS.txt.
set -uo pipefail
cd "$(dirname "$0")/.."

LIB=.claude/skills/analog-indexer/lib
DIR=index-out/shards-pw
SENT_DONE="$DIR/sentiment.jsonl.done"
STATUS=index-out/PIPELINE_STATUS.txt

while [ ! -f "$SENT_DONE" ]; do
  {
    echo "# PocketDJ pipeline — $(date)";
    node "$LIB/pipeline.mjs" status --dir "$DIR" 2>/dev/null;
  } > "$STATUS"
  # also refresh a browsable snapshot of the current index
  node "$LIB/pipeline.mjs" merge --dir "$DIR" --out-dir index-out/current >/dev/null 2>&1 && \
    cp index-out/current/index.json public/current-index.json 2>/dev/null || true
  sleep 300
done

echo "pipeline complete — merging + redeploying $(date)" >> "$STATUS"
node "$LIB/pipeline.mjs" merge --dir "$DIR" --out-dir index-out/full
# make the full real catalog the live default ("Load demo data") + a snapshot file
cp index-out/full/index.json public/mock-index.json
cp index-out/full/index.json public/current-index.json
node -e "const d=require('./index-out/full/index.json');console.log('FINAL: '+d.albums.length+' albums / '+d.songs.length+' songs, matched '+d.manifest.counts.albumsMatched+', lyrics '+d.manifest.counts.songsWithLyrics)" >> "$STATUS"

bash scripts/deploy.sh dev  >> /tmp/pocketdj-finish-deploy.log 2>&1 && echo "deployed dev $(date)"  >> "$STATUS"
bash scripts/deploy.sh prod >> /tmp/pocketdj-finish-deploy.log 2>&1 && echo "deployed prod $(date)" >> "$STATUS"
echo "DONE $(date)" >> "$STATUS"
