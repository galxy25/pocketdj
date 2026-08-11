#!/usr/bin/env bash
# Install/refresh the pocket rip-backfill launchd daemon. Idempotent — re-run any time.
# THE LEAD RUNS THIS — building the driver never installs it.
#
#   1. ~/.pocketdj/bin/rip-backfill-launcher.sh — stable out-of-repo entry point
#      (origin URL baked in from this repo's remote; runs from a clone pinned to origin/main,
#      so MERGE + PUSH the driver before installing).
#   2. ~/.pocketdj/rip-backfill.env — mode 0600, holds RIP_TOKEN / overrides. Created EMPTY
#      with a comment header if absent (the local server is tokenless today, so empty works).
#   3. ~/Library/LaunchAgents/com.pocketdj.rip-backfill.plist — KeepAlive(SuccessfulExit=false)
#      daemon pointing at the launcher, then (re)loaded into launchd. RunAtLoad starts the
#      pump IMMEDIATELY on load — that is the "start the backfill" moment.
#
# Precondition it checks: the source backup. The driver's stable path is
# ~/.pocketdj/backfill/source-backup.pocketdj (a future swap = one file copy onto that name);
# a dated source-backup-*.pocketdj beside it also works (newest wins, loudly).
#
# Stop:    launchctl unload ~/Library/LaunchAgents/com.pocketdj.rip-backfill.plist
# Resume:  launchctl load   ~/Library/LaunchAgents/com.pocketdj.rip-backfill.plist
# Monitor: tail -f ~/.pocketdj/rip-backfill.log        (grep HEARTBEAT for the JSON line)
#
# Sibling of scripts/install-rec-audio-nightly.sh (same launcher/env/plist pattern; this one is
# a KeepAlive daemon, not a timer).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ORIGIN="$(git -C "$REPO" remote get-url origin)"
BIN_DIR="$HOME/.pocketdj/bin"
LAUNCHER="$BIN_DIR/rip-backfill-launcher.sh"
ENV_FILE="$HOME/.pocketdj/rip-backfill.env"
PLIST="$HOME/Library/LaunchAgents/com.pocketdj.rip-backfill.plist"
LABEL="com.pocketdj.rip-backfill"
BACKUP_DIR="$HOME/.pocketdj/backfill"

if [ ! -e "$BACKUP_DIR/source-backup.pocketdj" ] && ! ls "$BACKUP_DIR"/source-backup*.pocketdj >/dev/null 2>&1; then
  echo "✗ no backup at $BACKUP_DIR/source-backup*.pocketdj — copy the device backup there first" >&2
  exit 1
fi

mkdir -p "$BIN_DIR"
sed "s#__POCKETDJ_ORIGIN__#$ORIGIN#" "$REPO/scripts/launchd/rip-backfill-launcher.sh" > "$LAUNCHER"
chmod +x "$LAUNCHER"

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<'EOF'
# PocketDJ rip-backfill daemon — overrides. Mode 0600; never put tokens in the plist
# (launchd plists are world-readable).
#RIP_SERVER=http://localhost:8787
#RIP_TOKEN=
#POCKETDJ_RIPBACKFILL_WINDOW=10
EOF
  chmod 600 "$ENV_FILE"
  echo "• created $ENV_FILE (empty is fine while the local server is tokenless)"
fi
chmod 600 "$ENV_FILE"

sed -e "s#__LAUNCHER__#$LAUNCHER#g" -e "s#__HOME__#$HOME#g" \
  "$REPO/scripts/launchd/com.pocketdj.rip-backfill.plist.template" > "$PLIST"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
launchctl list "$LABEL" >/dev/null || { echo "✗ $LABEL failed to load"; exit 1; }
echo "✓ launcher: $LAUNCHER"
echo "✓ env:      $ENV_FILE"
echo "✓ loaded:   $LABEL (pumping now; log: ~/.pocketdj/rip-backfill.log)"
echo "  stop:     launchctl unload $PLIST"
