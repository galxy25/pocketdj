#!/usr/bin/env bash
# Reclaim disk from PocketDJ's generated artifacts, everywhere they accumulate.
#
# Companion to scripts/lib/am-artifacts.mjs (which owns the Apple Music sync's own files and
# runs inside rip-server). This one covers the rest: indexer scratch, per-run residue, unbounded
# job ledgers, and logs that no one rotates.
#
# EVERY DELETION HERE IS EVIDENCE-BACKED. Adversarial review of an earlier draft refuted 10 of
# 26 "safe to delete" claims, so the NEVER list below is as load-bearing as the delete list:
#
#   ~/Downloads/Library.xml                                the user's manual Music.app export,
#                                                          4 live readers, not regenerable here
#   ~/.pocketdj/streaming-links/links-cache.ndjson         ~150 h of rate-limited crawling
#   ~/.pocketdj/am-catalog-vinyl-digital/catalog-cache.ndjson  9,479 resolved catalog ids
#   index-out/apple-music/catalog-cache.ndjson             the canonical multi-day crawl cache
#   index-out/apple-music/state.json                       the cron agent's ship cursor
#   ~/.pocketdj/am-sync/                                   live sync state (cursor, ghost strikes)
#   ~/.pocketdj/rips/manifest.json                         read by the app + three fold scripts
#   ~/.pocketdj/*nightly*.log                              the only record of 35 nightly syncs;
#                                                          this is the audit trail you read after
#                                                          a bad sync, so it rotates, never drops
#   apple-music-catalog-misses.csv                         git-tracked + backfill-rip's worklist
#
# Usage:  scripts/prune-artifacts.sh [--apply]        (default: dry run)
set -euo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
PDJ="$HOME/.pocketdj"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${POCKETDJ_AM_ARTIFACT_DIR:-$HOME/Documents/PocketDJ}"

say() { printf '%s\n' "$*"; }
run() { if [ "$APPLY" = 1 ]; then "$@"; else say "  DRY: $*"; fi; }
freed=0
note() { say "  → $1"; }

[ "$APPLY" = 1 ] || say "DRY RUN — pass --apply to actually remove"
say ""

# 1 · Orphan indexer sidecars ------------------------------------------------------------------
# index-apple-music.mjs streams songs to "<out>.songs.ndjson", reads it back ONCE in the same
# process to assemble index.json, and never unlinks it. The parent .json is cleaned up; the
# sidecar is not. Pure leak — nothing in the tree reads a .songs.ndjson after its own run.
say "1 · orphan .songs.ndjson sidecars"
find "$PDJ/rips" "$REPO/index-out" -name '*.json.songs.ndjson' -type f 2>/dev/null | while read -r f; do
  run rm -f "$f"
done
note "$(find "$PDJ/rips" "$REPO/index-out" -name '*.json.songs.ndjson' -type f 2>/dev/null | wc -l | tr -d ' ') file(s)"

# 2 · Transcoded digital audio -----------------------------------------------------------------
# index-digital-files.mjs transcodes each source file to 256k mp3, uploads it to the public rips
# bucket, and keeps the local copy ONLY as a "already transcoded, skip" marker plus a size
# comparison against S3. Verified 2026-08-02: all 846 local files exist in
# s3://pocketdj-rips-011183829623/rips/ with byte-identical sizes, 0 missing, 0 mismatched.
# Deleting them costs a re-transcode if the indexer is ever re-run over the same sources.
say "2 · transcoded digital audio (durable copies on S3)"
if [ -d "$PDJ/digital/audio" ]; then
  N=$(find "$PDJ/digital/audio" -name '*.mp3' | wc -l | tr -d ' ')
  say "  $N mp3(s), $(du -sh "$PDJ/digital/audio" | cut -f1)"
  say "  RE-VERIFYING against S3 before deleting…"
  if [ "$APPLY" = 1 ]; then
    aws s3 ls s3://pocketdj-rips-011183829623/rips/ --profile levi 2>/dev/null \
      | awk '{print $4, $3}' | grep '\.mp3' > /tmp/pdj-s3-rips.txt || true
    MISSING=$(cd "$PDJ/digital/audio" && for f in *.mp3; do
        grep -q "^$f " /tmp/pdj-s3-rips.txt || echo "$f"; done | wc -l | tr -d ' ')
    if [ "$MISSING" != "0" ]; then
      say "  ABORT: $MISSING local file(s) are NOT on S3 — keeping everything"
    else
      say "  all $N verified on S3 — removing local copies"
      rm -f "$PDJ/digital/audio"/*.mp3
    fi
  else
    say "  DRY: would re-verify all $N against S3, then rm"
  fi
fi

# 3 · Unbounded job ledgers --------------------------------------------------------------------
# jobs/<uuid>.json and sync-jobs/<uuid>.json are read ONLY while the app polls a live job
# (GET /rip/<id>, GET /am-sync/<id>). Both are explicitly exempt from the server's own GC, so
# they have kept every job since June. 7 days is far beyond any poll window.
say "3 · job ledgers older than 7 days"
for d in "$PDJ/rips/jobs" "$PDJ/rips/sync-jobs"; do
  [ -d "$d" ] || continue
  N=$(find "$d" -name '*.json' -mtime +7 | wc -l | tr -d ' ')
  say "  $(basename "$d"): $N of $(ls "$d" | wc -l | tr -d ' ') older than 7d"
  [ "$APPLY" = 1 ] && find "$d" -name '*.json' -mtime +7 -delete
done

# 4 · Per-run indexer residue ------------------------------------------------------------------
# Output directories of one-off runs that were already folded into public/*.json and shipped.
# catalog-cache.ndjson and state.json are NEVER matched here — see the NEVER list.
say "4 · folded/one-off run residue"
for d in "$REPO/index-out/lyrics-cloud" "$REPO/index-out/reindex" "$PDJ/am-export"; do
  [ -e "$d" ] || continue
  say "  $(du -sh "$d" | cut -f1)  $d"
  run rm -rf "$d"
done
for f in "$REPO/index-out/reduced-album-index.json" "$REPO/index-out/reduced-throwaway.json"; do
  [ -e "$f" ] || continue
  say "  $(du -sh "$f" | cut -f1)  $f"
  run rm -f "$f"
done

# 5 · Log rotation -----------------------------------------------------------------------------
# launchd appends and never truncates. Rotate rather than delete: the nightly logs are the only
# record of what each sync did, and this user has been burned by a bad sync before.
say "5 · rotate logs over 5 MB (keeping one .1 generation)"
find "$PDJ" -maxdepth 1 -name '*.log' -size +5M 2>/dev/null | while read -r f; do
  say "  $(du -sh "$f" | cut -f1)  $(basename "$f")"
  run mv "$f" "$f.1"
done

# 6 · Burn output sitting in the repo checkout -------------------------------------------------
# MOVED, not deleted: this is 106 tracks carved from vinyl, and while burn-manifest.json records
# exactly how to re-derive them (sourceFile + startMs/endMs), that needs the raw vinyl volume
# mounted. Out of the checkout is enough. `.nosync` keeps 1.6 GB out of iCloud Drive.
say "6 · burn output → $ARCHIVE/burns.nosync/"
run mkdir -p "$ARCHIVE/burns.nosync"
find "$REPO" -maxdepth 1 -type d \( -name '*take 3' -o -name '*_ripped' \) 2>/dev/null | while read -r d; do
  say "  $(du -sh "$d" | cut -f1)  $(basename "$d")"
  run mv "$d" "$ARCHIVE/burns.nosync/"
done

say ""
say "done."
