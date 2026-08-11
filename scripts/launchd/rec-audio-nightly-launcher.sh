#!/usr/bin/env bash
# PocketDJ targeted-audio-analysis nightly — stable launchd entry point. TEMPLATE: installed to
# ~/.pocketdj/bin/ by scripts/install-rec-audio-nightly.sh (which bakes __POCKETDJ_ORIGIN__).
#
# Same doctrine as the am-sync / digital-sync launchers: launchd must NOT invoke the dev
# checkout's copy, because whatever branch happens to be checked out at 02:00 would decide what
# code runs — and this repo is usually on a feature branch. This launcher lives OUTSIDE any
# checkout, keeps a dedicated clone pinned to origin/main, and runs the worker from there.
#
# Its OWN clone rather than sharing one with the other nightlies: those two fetch/reset/re-exec
# inside their clone, and a 02:00 job reading a worktree that a 04:00 job is about to rewrite is
# a race with no upside — the clone is a few hundred MB and the collision is silent.
set -euo pipefail

CLONE="${POCKETDJ_RECAUDIO_CLONE_DIR:-$HOME/.pocketdj/rec-audio-clone}"
ORIGIN="${POCKETDJ_NIGHTLY_ORIGIN:-__POCKETDJ_ORIGIN__}"
LOG="${POCKETDJ_RECAUDIO_LOG:-$HOME/.pocketdj/rec-audio-nightly.log}"
ENV_FILE="${POCKETDJ_RECAUDIO_ENV:-$HOME/.pocketdj/rec-audio.env}"
mkdir -p "$(dirname "$LOG")"
note() { echo "[rec-audio-launcher $(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

# Health check, not just existence: a SIGKILL/power loss mid-clone leaves .git present with no
# worktree, which would otherwise wedge every future 02:00 run identically.
healthy() {
  git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1 && [ -f "$CLONE/scripts/rec-audio-nightly.mjs" ]
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

# REC_ENGINE_BASE / REC_ENROLL_SECRET / RIP_TOKEN live in a mode-0600 env file, NEVER in the
# plist: a launchd plist is world-readable, and the enrollment secret is the worker's whole
# authority to read every profile's queue.
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a

note "starting (deadline ${POCKETDJ_RECAUDIO_UNTIL:-06:00})"
exec /usr/bin/env node "$CLONE/scripts/rec-audio-nightly.mjs" \
  --until "${POCKETDJ_RECAUDIO_UNTIL:-06:00}" "$@" >>"$LOG" 2>&1
