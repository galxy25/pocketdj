#!/usr/bin/env bash
# PocketDJ pocket rip backfill — stable launchd entry point. TEMPLATE: installed to
# ~/.pocketdj/bin/ by scripts/install-rip-backfill.sh (which bakes __POCKETDJ_ORIGIN__).
#
# Same doctrine as the rec-audio / am-sync / digital-sync launchers: launchd must NOT invoke the
# dev checkout's copy, because whatever branch happens to be checked out when the daemon
# (re)starts would decide what code runs — and this repo is usually on a feature branch. This
# launcher lives OUTSIDE any checkout, keeps a dedicated clone pinned to origin/main, and runs
# the driver from there. Its OWN clone (not shared with the nightlies): those fetch/reset inside
# their clones on their own schedules, and a KeepAlive daemon reading a worktree a 04:00 job is
# rewriting is a silent race.
#
# NOTE FOR THE LEAD: the driver must be MERGED + PUSHED to origin/main before installing —
# the clone resets to origin/main, so an unpushed local merge runs yesterday's code.
set -euo pipefail

CLONE="${POCKETDJ_RIPBACKFILL_CLONE_DIR:-$HOME/.pocketdj/rip-backfill-clone}"
ORIGIN="${POCKETDJ_NIGHTLY_ORIGIN:-__POCKETDJ_ORIGIN__}"
LOG="${POCKETDJ_RIPBACKFILL_LOG:-$HOME/.pocketdj/rip-backfill.log}"
ENV_FILE="${POCKETDJ_RIPBACKFILL_ENV:-$HOME/.pocketdj/rip-backfill.env}"
mkdir -p "$(dirname "$LOG")"
note() { echo "[rip-backfill-launcher $(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

# Health check, not just existence: a SIGKILL/power loss mid-clone leaves .git present with no
# worktree, which would otherwise wedge every future start identically.
healthy() {
  git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1 && [ -f "$CLONE/scripts/rip-backfill.mjs" ]
}
if [ -d "$CLONE" ] && ! healthy; then
  note "clone unhealthy — re-cloning"; rm -rf "$CLONE"
fi
if [ ! -d "$CLONE/.git" ]; then
  note "bootstrapping clone at $CLONE (from $ORIGIN)"
  git clone --branch main "$ORIGIN" "$CLONE" >>"$LOG" 2>&1
fi
rm -f "$CLONE/.git/index.lock"
git -C "$CLONE" fetch --quiet origin main >>"$LOG" 2>&1 || note "fetch failed — running the clone as-is"
git -C "$CLONE" reset --hard --quiet origin/main >>"$LOG" 2>&1 || true

# RIP_TOKEN (if the server is tokened) and any flag overrides (POCKETDJ_RIPS_BUCKET, RIP_SERVER)
# live in a mode-0600 env file, never in the world-readable plist.
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a

# The driver reads the backup from ~/.pocketdj/backfill/ and its indexes from the CLONE's
# public/ (kept fresh by the reset above — same files the rip server serves its catalog from).
note "starting pump (window ${POCKETDJ_RIPBACKFILL_WINDOW:-10})"
cd "$CLONE"
exec /usr/bin/env node "$CLONE/scripts/rip-backfill.mjs" \
  --window "${POCKETDJ_RIPBACKFILL_WINDOW:-10}" "$@" >>"$LOG" 2>&1
