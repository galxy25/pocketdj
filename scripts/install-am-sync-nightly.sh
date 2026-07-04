#!/usr/bin/env bash
# Install/refresh the nightly Apple Music sync launchd job. Idempotent — re-run any time.
#
#   1. ~/.pocketdj/bin/am-sync-nightly-launcher.sh — stable out-of-repo entry point
#      (origin URL baked in from this repo's remote).
#   2. ~/Library/LaunchAgents/com.pocketdj.am-sync-nightly.plist — 04:00 daily timer
#      pointing at the launcher (NOT at any checkout), then (re)loaded into launchd.
#
# After install, the 04:00 run: launcher → sync clone (~/.pocketdj/am-sync-clone, always
# origin/main) → am-sync-nightly.sh → am-incremental-sync → commit/push → deploy → search.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ORIGIN="$(git -C "$REPO" remote get-url origin)"
BIN_DIR="$HOME/.pocketdj/bin"
LAUNCHER="$BIN_DIR/am-sync-nightly-launcher.sh"
PLIST="$HOME/Library/LaunchAgents/com.pocketdj.am-sync-nightly.plist"
LABEL="com.pocketdj.am-sync-nightly"

mkdir -p "$BIN_DIR"
sed "s#__POCKETDJ_ORIGIN__#$ORIGIN#" "$REPO/scripts/launchd/am-sync-nightly-launcher.sh" > "$LAUNCHER"
chmod +x "$LAUNCHER"

sed -e "s#__LAUNCHER__#$LAUNCHER#g" -e "s#__HOME__#$HOME#g" \
  "$REPO/scripts/launchd/com.pocketdj.am-sync-nightly.plist.template" > "$PLIST"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
launchctl list "$LABEL" >/dev/null || { echo "✗ $LABEL failed to load"; exit 1; }
echo "✓ launcher: $LAUNCHER"
echo "✓ loaded:   $LABEL (04:00 daily; log: ~/.pocketdj/am-sync-nightly.log)"
