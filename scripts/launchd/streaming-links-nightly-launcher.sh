#!/usr/bin/env bash
# PocketDJ "streaming links" nightly backfill — stable launchd entry point. TEMPLATE: installed
# to ~/.pocketdj/bin/ by scripts/install-streaming-links-nightly.sh (which bakes __POCKETDJ_ORIGIN__).
#
# launchd must NOT invoke the dev checkout's copy of streaming-links-nightly.sh: whatever branch
# is checked out at 06:00 would decide what code runs (and this repo is often on a feature
# branch). This launcher lives OUTSIDE any checkout, only ensures the dedicated sync clone
# exists, and hands off to the clone's script — which self-syncs to origin/main and re-execs.
set -euo pipefail

CLONE="${POCKETDJ_NIGHTLY_CLONE_DIR:-$HOME/.pocketdj/streaming-links-clone}"
ORIGIN="${POCKETDJ_NIGHTLY_ORIGIN:-__POCKETDJ_ORIGIN__}"
LOG="${POCKETDJ_NIGHTLY_LOG:-$HOME/.pocketdj/streaming-links-nightly.log}"
mkdir -p "$(dirname "$LOG")"
note() { echo "[streaming-links-launcher $(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

# Health check, not just existence: a SIGKILL/power loss mid-clone leaves .git present with no
# worktree, which would otherwise wedge every future 06:00 run identically.
healthy() {
  git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1 && [ -f "$CLONE/scripts/streaming-links-nightly.sh" ]
}
if [ -d "$CLONE" ] && ! healthy; then
  note "sync clone unhealthy — re-cloning"; rm -rf "$CLONE"
fi
if [ ! -d "$CLONE/.git" ]; then
  note "bootstrapping sync clone at $CLONE (from $ORIGIN)"
  git clone --branch main "$ORIGIN" "$CLONE" >>"$LOG" 2>&1
fi
rm -f "$CLONE/.git/index.lock"

# Keep this launcher dumb: the clone's nightly script does the fetch/reset/re-exec + npm ci.
exec /bin/bash "$CLONE/scripts/streaming-links-nightly.sh" "$@"
