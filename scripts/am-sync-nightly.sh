#!/usr/bin/env bash
# PocketDJ Apple Music nightly sync — diff the live Music library against the committed
# index (scripts/am-incremental-sync.mjs: append only what changed) and ship the result.
#
# RUNS FROM ITS OWN CLONE, NOT THE DEV CHECKOUT: by default this script syncs a dedicated
# always-on-main clone (~/.pocketdj/am-sync-clone) and re-execs itself from there, so a
# feature branch left checked out in the dev repo at 04:00 can never starve the sync
# (which silently skipped 3 nights running, 2026-07-01..03). launchd should invoke the
# stable launcher (~/.pocketdj/bin/am-sync-nightly-launcher.sh, installed by
# scripts/install-am-sync-nightly.sh) — but invoking THIS script from any checkout works
# too: it bootstraps into the clone first. Set POCKETDJ_NIGHTLY_CLONE_DIR="" to run
# in-place (tests / legacy behavior, guarded to clean main as before).
#
# Ship order is LOAD-BEARING: GitHub commit/push (audit trail) BEFORE the S3 deploy.
# A deployed-index marker (~/.pocketdj/am-sync/last-deployed-index.sha256) closes the
# crash-between-push-and-deploy hole: a "no change" night still ships S3 + search if the
# committed index was never confirmed deployed.
#
# Overridable for tests/dry-run:
#   POCKETDJ_NIGHTLY_REPO      — the repo to sync from (default: this script's repo root).
#   POCKETDJ_NIGHTLY_CLONE_DIR — sync-clone path; set EMPTY to run in-place.
#   POCKETDJ_NIGHTLY_ORIGIN    — clone URL (default: the invoking repo's origin).
#   POCKETDJ_NODE_CMD / POCKETDJ_GIT_CMD / POCKETDJ_DEPLOY_CMD — shim the tools.
#   --dry-run — print every mutating step WITHOUT cloning/pulling/committing/deploying.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${POCKETDJ_NIGHTLY_REPO:-$(cd "$SELF_DIR/.." && pwd)}"
NODE="${POCKETDJ_NODE_CMD:-node}"
GIT="${POCKETDJ_GIT_CMD:-git}"
DEPLOY="${POCKETDJ_DEPLOY_CMD:-$REPO/scripts/deploy.sh}"
LOG="${POCKETDJ_NIGHTLY_LOG:-$HOME/.pocketdj/am-sync-nightly.log}"
INDEX="public/apple-music-index.json"
STATE_DIR="$HOME/.pocketdj/am-sync"
MARKER="$STATE_DIR/last-deployed-index.sha256"
# OpenSearch (online search) refresh after a successful ship. Default ON — the whole point is
# that a newly-added track shows up in online search the same night. Skip with POCKETDJ_SKIP_ES=1.
# Endpoint host comes from public/search-config.json (single source of truth; survives a
# collection swap / scale-to-zero rebuild), falling back to the current prod host.
ES_HOST_DEFAULT="mii9dwge3uiee2tvivt5.aoss.us-west-2.on.aws"
ES_HOST="$("$NODE" -e "try{process.stdout.write(JSON.parse(require('fs').readFileSync('$REPO/public/search-config.json','utf8')).host)}catch(e){process.stdout.write('$ES_HOST_DEFAULT')}" 2>/dev/null || echo "$ES_HOST_DEFAULT")"
ES_ENDPOINT="${POCKETDJ_ES_ENDPOINT:-https://$ES_HOST}"
ES_SOURCES="${POCKETDJ_ES_SOURCES:-public/current-index.json,public/apple-music-index.json,public/digital-index.json}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1
mkdir -p "$(dirname "$LOG")"
log() { echo "[am-sync-nightly $(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
run() { if [ "$DRY_RUN" = 1 ]; then echo "DRYRUN: $*" | tee -a "$LOG"; else "$@"; fi; }

# ---- clone-mode bootstrap ---------------------------------------------------------
# Not already in the clone → sync it to origin/main and re-exec the CLONE's copy of this
# script (so the running code is always fresh main, regardless of the invoking checkout).
CLONE_DIR="${POCKETDJ_NIGHTLY_CLONE_DIR-$HOME/.pocketdj/am-sync-clone}"
if [ -n "$CLONE_DIR" ] && [ "${POCKETDJ_NIGHTLY_IN_CLONE:-0}" != "1" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    log "(dry-run) would sync clone $CLONE_DIR and re-exec from it — continuing in-place"
  else
    ORIGIN="${POCKETDJ_NIGHTLY_ORIGIN:-$("$GIT" -C "$REPO" remote get-url origin)}"
    if [ ! -d "$CLONE_DIR/.git" ]; then
      log "creating sync clone at $CLONE_DIR (from $ORIGIN)"
      "$GIT" clone --branch main "$ORIGIN" "$CLONE_DIR" >>"$LOG" 2>&1
    fi
    "$GIT" -C "$CLONE_DIR" fetch origin main >>"$LOG" 2>&1 || log "⚠ clone fetch failed — proceeding with last-synced clone"
    "$GIT" -C "$CLONE_DIR" checkout -f main >>"$LOG" 2>&1
    # A crashed prior run may leave an unpushed nightly commit — discarding is safe: this
    # run regenerates the index from Music.app + origin/main and converges (the deploy
    # marker covers the pushed-but-not-deployed half of a crash).
    "$GIT" -C "$CLONE_DIR" reset --hard origin/main >>"$LOG" 2>&1
    export POCKETDJ_NIGHTLY_IN_CLONE=1 POCKETDJ_NIGHTLY_REPO="$CLONE_DIR"
    log "re-exec from sync clone $CLONE_DIR"
    exec /bin/bash "$CLONE_DIR/scripts/am-sync-nightly.sh" "$@"
  fi
fi

cd "$REPO"

# SAFE-BY-GUARD: never touch git unless the working tree is pristine on main. (In clone
# mode this is trivially true after the reset above; it still protects in-place runs.)
BRANCH="$("$GIT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [ "$BRANCH" != "main" ]; then log "repo on '$BRANCH' (not main) — skipping this run"; exit 0; fi
if [ -n "$("$GIT" status --porcelain)" ]; then log "working tree dirty — skipping this run"; exit 0; fi
run "$GIT" pull --ff-only origin main || { log "git pull failed — skipping this run"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/am-nightly.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
MERGED="$TMP/merged.json"

index_hash() { shasum -a 256 "$INDEX" | awk '{print $1}'; }

# The clone starts bare of node_modules; deploy.sh needs a build. Cheap no-op when fresh.
ensure_deps() {
  if [ ! -d node_modules ] || [ package-lock.json -nt node_modules/.package-lock.json ]; then
    log "installing build deps (npm ci)…"
    run npm ci --no-audit --no-fund --silent
  fi
}

# Deploy S3 dev+prod, record the deployed index hash, refresh online search.
ship() {
  ensure_deps
  run "$DEPLOY" dev
  run "$DEPLOY" prod
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRYRUN: write deploy marker $MARKER" | tee -a "$LOG"
  else
    mkdir -p "$STATE_DIR"
    index_hash > "$MARKER"
  fi
  # Refresh OpenSearch so the added/removed tracks show up in the app's ONLINE search. NON-FATAL:
  # the catalog is already committed + on S3, so a search hiccup just lags until the next change.
  # es-index does a FULL reset (delete → recreate → bulk-load, ~40s); `_id` is the item id, so
  # it's an idempotent upsert of the whole corpus from the now-updated public/*.json. Optional
  # lyrics via POCKETDJ_ES_LYRICS_BASE (default off — new digital tracks rarely carry lyrics).
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
}

log "running incremental sync…"
"$NODE" "$REPO/scripts/am-incremental-sync.mjs" --index "$INDEX" --out "$MERGED" --repo "$REPO" 2>&1 | tee -a "$LOG"

if cmp -s "$MERGED" "$INDEX"; then
  if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$(index_hash)" ]; then
    log "no change — nothing to ship"
    exit 0
  fi
  log "no index change, but this index isn't confirmed deployed — shipping S3 + search only"
  ship
  log "shipped (S3/search catch-up)."
  exit 0
fi

log "index changed — shipping (GitHub → S3)"
run cp "$MERGED" "$INDEX"
run "$GIT" add "$INDEX"
run "$GIT" commit -m "Apple Music sync: incremental $(date -u +%FT%TZ)"
run "$GIT" push origin main
ship
log "shipped."
