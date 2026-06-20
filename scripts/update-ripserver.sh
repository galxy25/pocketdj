#!/usr/bin/env bash
# Update the PocketDJ rip server in one shot: pull the latest main into the checkout
# the launchd agent runs from, restart the service (KeepAlive-managed), and verify it
# came back healthy with the expected protocol version. Fixes the "stale server process
# keeps old in-memory code after a pull" trap.
#
#   scripts/update-ripserver.sh
#
# Override the checkout with POCKETDJ_REPO=… if it lives elsewhere.
set -euo pipefail

REPO="${POCKETDJ_REPO:-/Users/deepspacenine/forges/levi/pocketdj}"  # checkout the launchd agent runs from
LABEL="com.pocketdj.ripserver"
PORT="${RIP_PORT:-8787}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "▶ pulling latest in $REPO …"
git -C "$REPO" pull --ff-only

echo "▶ restarting $LABEL …"
if launchctl list "$LABEL" >/dev/null 2>&1; then  # exits non-zero if not loaded
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
elif [ -f "$PLIST" ]; then
  echo "  (agent not loaded — loading it)"
  launchctl load "$PLIST"
else
  echo "✗ launchd agent not installed — copy scripts/launchd/$LABEL.plist to ~/Library/LaunchAgents/ first" >&2
  exit 1
fi

echo "▶ waiting for health on :$PORT …"
for _ in $(seq 1 15); do
  curl -s -m 2 "http://localhost:$PORT/health" >/dev/null 2>&1 && break
  sleep 1
done

curl -s -m 3 "http://localhost:$PORT/health" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"✓ rip server up — version {d.get('version')}, hls={d.get('hls')}, cached {d.get('cached')} songs\")" \
  || { echo "✗ server did not come up — check ~/.pocketdj/rip-server.log" >&2; exit 1; }
