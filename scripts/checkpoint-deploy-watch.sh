#!/usr/bin/env bash
# Auto checkpoint-deploy watcher for the Apple Music catalog-id crawl.
#
# The resolver (scripts/resolve-apple-music-catalog.mjs) runs for ~2 days, growing
# index-out/apple-music/index.json with more `appleMusicId`s over time. This watcher
# periodically snapshots that growing index into public/apple-music-index.json and
# redeploys the PWA (dev + prod) whenever coverage has grown past a threshold, plus a
# final deploy when the crawl finishes. Runs detached (nohup) — independent of any
# Claude session, uses local AWS creds + the local index files.
#
#   nohup scripts/checkpoint-deploy-watch.sh >/dev/null 2>&1 &
#
# Tunables (env): THRESHOLD (new resolved ids before a redeploy), INTERVAL (seconds).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

SRC=index-out/apple-music/index.json
DST=public/apple-music-index.json
MARK=index-out/apple-music/.last-deploy-count
WATCHLOG=index-out/apple-music/checkpoint-deploy.log
THRESHOLD=${THRESHOLD:-10000}
INTERVAL=${INTERVAL:-5400}     # 90 min

count() { python3 -c "import json;d=json.load(open('$SRC'));print(sum(1 for s in d['songs'] if s.get('appleMusicId')))" 2>/dev/null || echo 0; }
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WATCHLOG"; }

deploy() {
  local c="$1"
  log "deploying snapshot: $c songs with appleMusicId"
  cp "$SRC" "$DST"
  if scripts/deploy.sh dev >> "$WATCHLOG" 2>&1 && SKIP_BUILD=1 scripts/deploy.sh prod >> "$WATCHLOG" 2>&1; then
    echo "$c" > "$MARK"; log "✓ deployed dev+prod at $c"
  else
    log "✗ deploy failed at $c (will retry next tick)"
  fi
}

[ -f "$MARK" ] || echo 0 > "$MARK"
log "watcher started (threshold=$THRESHOLD interval=${INTERVAL}s)"
while true; do
  cur=$(count); last=$(cat "$MARK" 2>/dev/null || echo 0)
  running=0; pgrep -f resolve-apple-music-catalog.mjs >/dev/null && running=1
  log "tick: cur=$cur last=$last running=$running"
  if [ "$running" -eq 0 ]; then
    # crawl process gone (finished, or stopped) — capture any remaining progress and exit.
    [ "$cur" -gt "$last" ] && deploy "$cur"
    log "crawl no longer running — exiting watcher"
    exit 0
  fi
  [ $((cur - last)) -ge "$THRESHOLD" ] && deploy "$cur"
  sleep "$INTERVAL"
done
