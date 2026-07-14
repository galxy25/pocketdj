#!/bin/bash
# Capture the Now Playing debug trace (category "nowplaying") from BOTH the app and the
# widget-extension process, live, into a timestamped file — Ctrl-C to stop.
#
#   ./scripts/np-trace.sh              # stream live to np-trace-<time>.txt (and the terminal)
#   ./scripts/np-trace.sh --last 10m   # instead dump the LAST 10 minutes (after a repro)
#
# What to look for:
#   [app]    engine card WRITE …    ← every MPNowPlayingInfoCenter write we make (dupe-card hunt)
#   [app]    arbiter claim/resign   ← which engine owns the card
#   [app]    cover WROTE/FAILED …   ← the widget cover pipeline (missing-art hunt)
#   [widget] timeline read …        ← what the widget process actually sees (coverBytes!)
set -euo pipefail
PRED='subsystem == "com.levi.pocketdj" AND category == "nowplaying"'
OUT="np-trace-$(date +%H%M%S).txt"
if [ "${1:-}" = "--last" ]; then
  log show --last "${2:-10m}" --info --debug --predicate "$PRED" | tee "$OUT"
else
  echo "streaming Now Playing trace → $OUT   (Ctrl-C to stop)"
  log stream --info --debug --predicate "$PRED" | tee "$OUT"
fi
echo "saved: $OUT"
