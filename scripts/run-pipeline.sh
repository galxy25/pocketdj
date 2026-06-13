#!/usr/bin/env bash
# Streaming indexer pipeline. The stages are DECOUPLED — metadata keeps fetching
# continuously while lyrics and sentiment flow in behind it, each at its own
# concurrency. A slow stage never blocks a faster upstream one.
#
#   metadata (enrich-playwright, run separately/in background)  -> enriched.jsonl
#   lyrics   (this script)                                       -> lyrics.jsonl
#   sentiment(this script)                                       -> sentiment.jsonl
#
# Each worker re-invokes its RESUMABLE sub-indexer in a loop: every pass picks up
# whatever new records the upstream has produced, until the upstream is done
# (its `.done` marker, or its process exited) AND this stage has caught up.
#
#   scripts/run-pipeline.sh            # start lyrics + sentiment workers (foreground; ^C to stop)
#   LYR_CONC=4 SENT_CONC=6 scripts/run-pipeline.sh
#   SENT_MODEL=google/gemma-4-26b-a4b scripts/run-pipeline.sh
#
# Knobs (env): LYR_CONC (lyrics pages), SENT_CONC (parallel model calls),
# SENT_MODEL (LM Studio model id), POLL (seconds between catch-up passes).
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${DIR:-index-out/shards-pw}
META="$DIR/enriched.jsonl"
LYR="$DIR/lyrics.jsonl"
SENT="$DIR/sentiment.jsonl"
PROG=${PROG:-index-out/pipe-progress.log}
LIB=.claude/skills/analog-indexer/lib

LYR_CONC=${LYR_CONC:-3}
SENT_CONC=${SENT_CONC:-4}
SENT_MODEL=${SENT_MODEL:-google/gemma-4-e4b}
POLL=${POLL:-20}

count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
meta_done() { [ -f "$META.done" ] || ! pgrep -f 'enrich-playwright.mjs index-out/parsed-full' >/dev/null; }

lyrics_worker() {
  while true; do
    node "$LIB/enrich-lyrics.mjs" --in "$META" --out "$LYR" \
      --concurrency "$LYR_CONC" --progress-file "$PROG" 2>>/tmp/pocketdj-lyrics.log || true
    if meta_done && [ "$(count "$LYR")" -ge "$(count "$META")" ]; then
      : > "$LYR.done"; echo "[lyrics] complete ($(count "$LYR") albums)"; break
    fi
    sleep "$POLL"
  done
}

sentiment_worker() {
  while true; do
    node "$LIB/enrich-sentiment.mjs" --in "$LYR" --out "$SENT" \
      --concurrency "$SENT_CONC" --model "$SENT_MODEL" --progress-file "$PROG" 2>>/tmp/pocketdj-sentiment.log || true
    if [ -f "$LYR.done" ] && [ "$(count "$SENT")" -ge "$(count "$LYR")" ]; then
      : > "$SENT.done"; echo "[sentiment] complete ($(count "$SENT") albums)"; break
    fi
    sleep "$POLL"
  done
}

echo "streaming pipeline: lyrics(conc=$LYR_CONC) + sentiment(conc=$SENT_CONC, $SENT_MODEL) — metadata runs decoupled"
lyrics_worker &
LPID=$!
sentiment_worker &
SPID=$!
trap 'kill $LPID $SPID 2>/dev/null' INT TERM
wait
