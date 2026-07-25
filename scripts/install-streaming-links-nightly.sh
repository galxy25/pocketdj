#!/usr/bin/env bash
# Install/refresh the nightly "streaming links" backfill launchd job. Idempotent — re-run any time.
#
#   1. ~/.pocketdj/bin/streaming-links-nightly-launcher.sh — stable out-of-repo entry point
#      (origin URL baked in from this repo's remote).
#   2. ~/Library/LaunchAgents/com.pocketdj.streaming-links-nightly.plist — 06:00 daily timer
#      pointing at the launcher (NOT at any checkout), then (re)loaded into launchd.
#
# After install, the 06:00 run: launcher → sync clone (~/.pocketdj/streaming-links-clone, always
# origin/main) → npm ci (playwright) → streaming-links-nightly.sh → fold-apple-music-links →
# resolve a BATCH of Spotify/YouTube links (resumable, persistent cache) → fold-streaming-links →
# commit/push (GitHub first) → publish changed indexes (prod: vinyl+Apple Music, dev: My Digital).
# Sibling of scripts/install-digital-sync-nightly.sh.
#
# ONE-SHOT full backfill (optional, before/instead of waiting for nightlies to fill ~94k songs
# at ~14/min ≈ ~1-2 weeks): run the resolver directly with no --limit, e.g.
#   node scripts/resolve-streaming-links.mjs --index apple-music \
#     --cache ~/.pocketdj/streaming-links/links-cache.ndjson
#   node scripts/resolve-streaming-links.mjs --index current  --cache ~/.pocketdj/streaming-links/links-cache.ndjson
#   node scripts/resolve-streaming-links.mjs --index digital  --cache ~/.pocketdj/streaming-links/links-cache.ndjson
# then fold-streaming-links.mjs --apply --upload dev,prod. The nightly then just tops up new songs.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ORIGIN="$(git -C "$REPO" remote get-url origin)"
BIN_DIR="$HOME/.pocketdj/bin"
LAUNCHER="$BIN_DIR/streaming-links-nightly-launcher.sh"
PLIST="$HOME/Library/LaunchAgents/com.pocketdj.streaming-links-nightly.plist"
LABEL="com.pocketdj.streaming-links-nightly"

mkdir -p "$BIN_DIR"
sed "s#__POCKETDJ_ORIGIN__#$ORIGIN#" "$REPO/scripts/launchd/streaming-links-nightly-launcher.sh" > "$LAUNCHER"
chmod +x "$LAUNCHER"

sed -e "s#__LAUNCHER__#$LAUNCHER#g" -e "s#__HOME__#$HOME#g" \
  "$REPO/scripts/launchd/com.pocketdj.streaming-links-nightly.plist.template" > "$PLIST"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
launchctl list "$LABEL" >/dev/null || { echo "✗ $LABEL failed to load"; exit 1; }
echo "✓ launcher: $LAUNCHER"
echo "✓ loaded:   $LABEL (06:00 daily; log: ~/.pocketdj/streaming-links-nightly.log)"
