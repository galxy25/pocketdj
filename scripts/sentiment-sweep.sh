#!/usr/bin/env bash
# Local-model SENTIMENT SWEEP — runs the local sentiment sub-indexer over a GROWING
# input file IN PARALLEL with an upstream producer (typically the lyrics stage), so
# sentiment fills in as fast as lyrics arrive instead of waiting for lyrics to finish.
#
# Each pass re-runs enrich-sentiment.mjs (RESUMABLE — skips albums already in --out by
# candidateIndex), so it only tags newly-completed albums. It keeps sweeping until the
# upstream producer has finished, then does one final catch-up pass and exits.
#
# Resource note: this pairs well with the lyrics scraper because lyrics is network-bound
# (Playwright) and local sentiment is GPU/LM-Studio-bound — they don't contend. (For the
# CLOUD sentiment path use the Claude workflow instead; see workflow/sentiment-upgrade.workflow.js.)
#
#   scripts/sentiment-sweep.sh
#   IN=/tmp/lyrics-backfill-out.jsonl OUT=/tmp/sentiment-backfill-out.jsonl scripts/sentiment-sweep.sh
#
# Knobs (env): IN (growing album JSONL w/ lyrics), OUT (sentiment JSONL), SENT_CONC
# (parallel model calls, default 2), POLL (seconds between passes, default 180),
# SENT_MODEL (LM Studio model id), UNTIL_PROC (regex of the upstream process to wait on,
# default enrich-lyrics.mjs), LOG / STDOUT (progress + console capture paths).
set -uo pipefail
cd "$(dirname "$0")/.."

IN="${IN:-/tmp/lyrics-backfill-out.jsonl}"
OUT="${OUT:-/tmp/sentiment-backfill-out.jsonl}"
LOG="${LOG:-/tmp/sentiment-sweep.log}"
STDOUT="${STDOUT:-/tmp/sentiment-sweep.stdout}"
SENT_CONC="${SENT_CONC:-2}"
POLL="${POLL:-180}"
SENT_MODEL="${SENT_MODEL:-google/gemma-4-e4b}"
UNTIL_PROC="${UNTIL_PROC:-enrich-lyrics.mjs}"

echo "sentiment-sweep start $(date -u +%FT%TZ) IN=$IN OUT=$OUT conc=$SENT_CONC waiting-on=/$UNTIL_PROC/" >> "$STDOUT"
while true; do
  upstream_alive=1
  pgrep -f "$UNTIL_PROC" >/dev/null || upstream_alive=0
  node .claude/skills/analog-indexer/lib/enrich-sentiment.mjs \
    --in "$IN" --out "$OUT" --concurrency "$SENT_CONC" --model "$SENT_MODEL" \
    --progress-file "$LOG" >> "$STDOUT" 2>&1
  if [ "$upstream_alive" = "0" ]; then
    echo "sentiment-sweep: DONE (upstream finished before this pass) $(date -u +%FT%TZ)" >> "$STDOUT"
    break
  fi
  sleep "$POLL"
done
