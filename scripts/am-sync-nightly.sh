#!/usr/bin/env bash
# PocketDJ Apple Music nightly sync — diff the live Music library against the committed
# index (scripts/am-incremental-sync.mjs: append only what changed) and ship the result.
#
# Replaces the old change-set → full-rebuild pipeline (rip-server detection + am-sync-agent):
# incremental is seconds, not the ~6h full AppleScript export the full-rebuild needed.
#
# INERT until installed via launchd (scripts/launchd/com.pocketdj.am-sync-nightly.plist.template).
# Runs from the working repo by default. SAFE-BY-GUARD: it only pulls/commits/ships when the
# repo is on `main` AND clean, so it never disrupts in-progress dev — it just skips that night
# and recovers the next. A no-change night is a true no-op (am-incremental-sync emits a
# byte-identical file → the `cmp` below short-circuits before any git/deploy).
#
# Ship order is LOAD-BEARING: GitHub commit/push (audit trail) BEFORE the S3 deploy, so a crash
# between them re-runs and re-deploys from the committed file and converges.
#
# Overridable for tests/dry-run:
#   POCKETDJ_NIGHTLY_REPO  — the repo to sync from (default: this script's repo root).
#   POCKETDJ_NODE_CMD / POCKETDJ_GIT_CMD / POCKETDJ_DEPLOY_CMD — shim the tools.
#   --dry-run — print every mutating step WITHOUT pulling/committing/pushing/deploying.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${POCKETDJ_NIGHTLY_REPO:-$(cd "$SELF_DIR/.." && pwd)}"
NODE="${POCKETDJ_NODE_CMD:-node}"
GIT="${POCKETDJ_GIT_CMD:-git}"
DEPLOY="${POCKETDJ_DEPLOY_CMD:-$REPO/scripts/deploy.sh}"
LOG="${POCKETDJ_NIGHTLY_LOG:-$HOME/.pocketdj/am-sync-nightly.log}"
INDEX="public/apple-music-index.json"
# OpenSearch (online search) refresh after a successful ship. Default ON — the whole point is
# that a newly-added track shows up in online search the same night. Skip with POCKETDJ_SKIP_ES=1.
ES_ENDPOINT="${POCKETDJ_ES_ENDPOINT:-https://zxvkpgoc5ivtrbqp37s5.us-west-2.aoss.amazonaws.com}"
ES_SOURCES="${POCKETDJ_ES_SOURCES:-public/current-index.json,public/apple-music-index.json,public/digital-index.json}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1
mkdir -p "$(dirname "$LOG")"
log() { echo "[am-sync-nightly $(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
run() { if [ "$DRY_RUN" = 1 ]; then echo "DRYRUN: $*" | tee -a "$LOG"; else "$@"; fi; }

cd "$REPO"

# SAFE-BY-GUARD: never touch git unless the working tree is pristine on main.
BRANCH="$("$GIT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [ "$BRANCH" != "main" ]; then log "repo on '$BRANCH' (not main) — skipping this run"; exit 0; fi
if [ -n "$("$GIT" status --porcelain)" ]; then log "working tree dirty — skipping this run"; exit 0; fi
run "$GIT" pull --ff-only origin main || { log "git pull failed — skipping this run"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/am-nightly.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
MERGED="$TMP/merged.json"

log "running incremental sync…"
"$NODE" "$REPO/scripts/am-incremental-sync.mjs" --index "$INDEX" --out "$MERGED" --repo "$REPO" 2>&1 | tee -a "$LOG"

if cmp -s "$MERGED" "$INDEX"; then
  log "no change — nothing to ship"
  exit 0
fi

log "index changed — shipping (GitHub → S3)"
run cp "$MERGED" "$INDEX"
run "$GIT" add "$INDEX"
run "$GIT" commit -m "Apple Music sync: incremental $(date -u +%FT%TZ)"
run "$GIT" push origin main
run "$DEPLOY" dev
run "$DEPLOY" prod

# Refresh OpenSearch so the added/removed tracks show up in the app's ONLINE search. NON-FATAL:
# the catalog is already committed + on S3, so a search hiccup just retries next run. es-index
# does a FULL reset (delete → recreate → bulk-load, ~40s); `_id` is the item id, so it's an
# idempotent upsert of the whole corpus from the now-updated public/*.json. Optional lyrics via
# POCKETDJ_ES_LYRICS_BASE (default off — fast; new digital tracks rarely carry lyrics anyway).
if [ "${POCKETDJ_SKIP_ES:-0}" != "1" ]; then
  log "refreshing OpenSearch (online search) index…"
  LYRICS_ARG=()
  [ -n "${POCKETDJ_ES_LYRICS_BASE:-}" ] && LYRICS_ARG=(--lyrics-base "$POCKETDJ_ES_LYRICS_BASE")
  run "$NODE" "$REPO/scripts/es-index.mjs" \
    --endpoint "$ES_ENDPOINT" --index pocketdj \
    --profile "${AWS_PROFILE:-levi}" --region "${AWS_REGION:-us-west-2}" \
    --sources "$ES_SOURCES" ${LYRICS_ARG[@]+"${LYRICS_ARG[@]}"} \
    || log "⚠ OpenSearch reindex failed (non-fatal) — online search may lag until the next run"
fi
log "shipped."
