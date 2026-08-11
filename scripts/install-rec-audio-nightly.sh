#!/usr/bin/env bash
# Install/refresh the nightly targeted-audio-analysis launchd job. Idempotent — re-run any time.
#
#   1. ~/.pocketdj/bin/rec-audio-nightly-launcher.sh — stable out-of-repo entry point
#      (origin URL baked in from this repo's remote).
#   2. ~/.pocketdj/rec-audio.env — mode 0600, holds REC_ENGINE_BASE / REC_ENROLL_SECRET /
#      RIP_TOKEN. Created EMPTY with a comment header if absent; the job is a harmless no-op
#      ("no --engine / REC_ENROLL_SECRET — nothing to drain") until it is filled in, which is
#      the right failure mode for a credential this script cannot invent.
#   3. ~/Library/LaunchAgents/com.pocketdj.rec-audio-nightly.plist — 02:00 daily timer pointing
#      at the launcher (NOT at any checkout), then (re)loaded into launchd.
#
# Sibling of scripts/install-digital-sync-nightly.sh and scripts/install-am-sync-nightly.sh.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ORIGIN="$(git -C "$REPO" remote get-url origin)"
BIN_DIR="$HOME/.pocketdj/bin"
LAUNCHER="$BIN_DIR/rec-audio-nightly-launcher.sh"
ENV_FILE="$HOME/.pocketdj/rec-audio.env"
PLIST="$HOME/Library/LaunchAgents/com.pocketdj.rec-audio-nightly.plist"
LABEL="com.pocketdj.rec-audio-nightly"

mkdir -p "$BIN_DIR"
sed "s#__POCKETDJ_ORIGIN__#$ORIGIN#" "$REPO/scripts/launchd/rec-audio-nightly-launcher.sh" > "$LAUNCHER"
chmod +x "$LAUNCHER"

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<'EOF'
# PocketDJ rec-audio nightly — worker credentials. Mode 0600; never put these in the plist
# (launchd plists are world-readable and the enrollment secret is this worker's whole authority).
#REC_ENGINE_BASE=https://<api-id>.execute-api.us-west-2.amazonaws.com
#REC_ENROLL_SECRET=
#RIP_SERVER=http://localhost:8787
#RIP_TOKEN=
EOF
  chmod 600 "$ENV_FILE"
  echo "• created $ENV_FILE (fill in REC_ENGINE_BASE + REC_ENROLL_SECRET to arm the job)"
fi
chmod 600 "$ENV_FILE"

sed -e "s#__LAUNCHER__#$LAUNCHER#g" -e "s#__HOME__#$HOME#g" \
  "$REPO/scripts/launchd/com.pocketdj.rec-audio-nightly.plist.template" > "$PLIST"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
launchctl list "$LABEL" >/dev/null || { echo "✗ $LABEL failed to load"; exit 1; }
echo "✓ launcher: $LAUNCHER"
echo "✓ env:      $ENV_FILE"
echo "✓ loaded:   $LABEL (02:00 daily, hard stop 06:00; log: ~/.pocketdj/rec-audio-nightly.log)"
