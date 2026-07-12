#!/usr/bin/env bash
# Install/refresh the nightly "My Digital" indexer launchd job. Idempotent — re-run any time.
#
#   1. ~/.pocketdj/bin/digital-sync-nightly-launcher.sh — stable out-of-repo entry point
#      (origin URL baked in from this repo's remote).
#   2. ~/Library/LaunchAgents/com.pocketdj.digital-sync-nightly.plist — 05:00 daily timer
#      pointing at the launcher (NOT at any checkout), then (re)loaded into launchd.
#
# After install, the 05:00 run: launcher → sync clone (~/.pocketdj/digital-sync-clone, always
# origin/main) → digital-sync-nightly.sh → index-digital-files (incremental) → commit/push →
# publish index (dev) → search → stem backfill. Sibling of scripts/install-am-sync-nightly.sh.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ORIGIN="$(git -C "$REPO" remote get-url origin)"
BIN_DIR="$HOME/.pocketdj/bin"
LAUNCHER="$BIN_DIR/digital-sync-nightly-launcher.sh"
PLIST="$HOME/Library/LaunchAgents/com.pocketdj.digital-sync-nightly.plist"
LABEL="com.pocketdj.digital-sync-nightly"

mkdir -p "$BIN_DIR"
sed "s#__POCKETDJ_ORIGIN__#$ORIGIN#" "$REPO/scripts/launchd/digital-sync-nightly-launcher.sh" > "$LAUNCHER"
chmod +x "$LAUNCHER"

sed -e "s#__LAUNCHER__#$LAUNCHER#g" -e "s#__HOME__#$HOME#g" \
  "$REPO/scripts/launchd/com.pocketdj.digital-sync-nightly.plist.template" > "$PLIST"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
launchctl list "$LABEL" >/dev/null || { echo "✗ $LABEL failed to load"; exit 1; }
echo "✓ launcher: $LAUNCHER"
echo "✓ loaded:   $LABEL (05:00 daily; log: ~/.pocketdj/digital-sync-nightly.log)"
