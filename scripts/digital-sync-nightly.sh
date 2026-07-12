#!/usr/bin/env bash
# PocketDJ "My Digital" nightly indexer — pick up newly-burned CDs (and any other new
# files) under the digital-library root, index ONLY what's new, and ship the result.
#
# Sibling of scripts/am-sync-nightly.sh (Apple Music). Same shape, same robustness — a
# dedicated always-on-main clone, single-instance lock, audit-trail-before-S3 ordering,
# a deploy marker for the crash-between-commit-and-publish hole, and a shrink circuit
# breaker — but the "sync" is a filesystem walk of the burn root instead of a Music.app
# query, and the work is HEAVY (transcode + audio analysis + S3 upload + stems).
#
# INCREMENTAL BY WORK DIR: scripts/index-digital-files.mjs rebuilds the whole index from
# a full walk each run, but its transcode/analyze/upload stages SKIP anything already done
# (state persists in $WORK = ~/.pocketdj/digital + S3 existence checks). So a nightly run
# only does real work for NEW album folders; existing songs re-emit with the SAME
# content-stable ids (no churn), so the git diff shows only the added songs.
#
# Ship order is LOAD-BEARING: GitHub commit/push (audit trail) BEFORE the S3 index publish
# (audio + cover art already streamed to S3 during the walk — those are additive/immutable
# and only become reachable once the published index references them). "My Digital" is
# served from the DEV web bucket + dev CloudFront (Config.digitalIndexURL → catalogBase),
# so shipping is dev-only + the git audit commit + an OpenSearch refresh — no app rebuild.
#
# Overridable for tests/dry-run:
#   POCKETDJ_DIGITAL_ROOT        — the burn/library root to walk (default below).
#   POCKETDJ_NIGHTLY_CLONE_DIR   — sync-clone path; set EMPTY to run in-place.
#   POCKETDJ_NIGHTLY_REPO / _ORIGIN — repo + clone URL (default: this script's repo).
#   POCKETDJ_RIP_SERVER          — rip-server base (default http://127.0.0.1:8787).
#   POCKETDJ_DIGITAL_STEMS=0     — skip the post-ingest stem backfill.
#   POCKETDJ_ALLOW_DIGITAL_SHRINK=1 — override the "index shrank" circuit breaker.
#   POCKETDJ_NODE_CMD / POCKETDJ_GIT_CMD — shim the tools.
#   --dry-run — print every mutating step WITHOUT cloning/committing/publishing.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${POCKETDJ_NIGHTLY_REPO:-$(cd "$SELF_DIR/.." && pwd)}"
NODE="${POCKETDJ_NODE_CMD:-node}"
GIT="${POCKETDJ_GIT_CMD:-git}"
LOG="${POCKETDJ_NIGHTLY_LOG:-$HOME/.pocketdj/digital-sync-nightly.log}"
INDEX="public/digital-index.json"
ROOT="${POCKETDJ_DIGITAL_ROOT:-/Volumes/RipBurnMix/Pocket DJ}"
RIP_SERVER="${POCKETDJ_RIP_SERVER:-http://127.0.0.1:8787}"
WORK="${POCKETDJ_DIGITAL_WORK:-$HOME/.pocketdj/digital}"
STATE_DIR="$HOME/.pocketdj/digital-sync"
MARKER="$STATE_DIR/last-published-index.sha256"
PROFILE="${AWS_PROFILE:-levi}"
REGION="${AWS_REGION:-us-west-2}"
# Dev web bucket + CloudFront that serve "My Digital" (art uploaded during the walk; the
# index published here in ship()). CF dev distribution = E123GKAO9JVETP.
CF_DEV="E123GKAO9JVETP"
# OpenSearch (online search) refresh after a ship — so new tracks are online-searchable the
# same night. Host from public/search-config.json (single source of truth), else prod host.
ES_HOST_DEFAULT="mii9dwge3uiee2tvivt5.aoss.us-west-2.on.aws"
ES_HOST="$("$NODE" -e "try{process.stdout.write(JSON.parse(require('fs').readFileSync('$REPO/public/search-config.json','utf8')).host)}catch(e){process.stdout.write('$ES_HOST_DEFAULT')}" 2>/dev/null || echo "$ES_HOST_DEFAULT")"
ES_ENDPOINT="${POCKETDJ_ES_ENDPOINT:-https://$ES_HOST}"
ES_SOURCES="${POCKETDJ_ES_SOURCES:-public/current-index.json,public/apple-music-index.json,public/digital-index.json}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1
mkdir -p "$(dirname "$LOG")"
log() { echo "[digital-sync-nightly $(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
run() { if [ "$DRY_RUN" = 1 ]; then echo "DRYRUN: $*" | tee -a "$LOG"; else "$@"; fi; }

# Normalized index hash — IGNORES manifest.generatedAt (the indexer stamps a fresh one every
# run), so an unchanged catalog compares equal night-to-night. Used for both change detection
# and the publish marker. Prints "ERR" on a missing/corrupt file (never a false match).
norm_hash() {
  "$NODE" -e '
    const fs=require("fs"),crypto=require("crypto");
    try{const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      if(j&&j.manifest)delete j.manifest.generatedAt;
      process.stdout.write(crypto.createHash("sha256").update(JSON.stringify(j)).digest("hex"));
    }catch(e){process.stdout.write("ERR")}' "$1"
}
song_count() {
  "$NODE" -e '
    try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      process.stdout.write(String((j.songs&&j.songs.length)||(j.manifest&&j.manifest.counts&&j.manifest.counts.songs)||0));
    }catch(e){process.stdout.write("0")}' "$1"
}

# Single-instance lock (mkdir is atomic; macOS has no flock). The 05:00 launchd run and a
# manual invocation share one clone — the lock stops them resetting --hard under each other.
LOCK_DIR="$STATE_DIR/.sync.lock"
acquire_lock() {
  mkdir -p "$STATE_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then echo $$ > "$LOCK_DIR/pid"; return 0; fi
  local pid; pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ "$pid" = "$$" ]; then return 0; fi
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
  rm -rf "$LOCK_DIR" && mkdir "$LOCK_DIR" 2>/dev/null && echo $$ > "$LOCK_DIR/pid"
}
cleanup() {
  if [ -n "${TMP:-}" ]; then rm -rf "$TMP"; fi
  if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then rm -rf "$LOCK_DIR"; fi
}
if [ "$DRY_RUN" != 1 ]; then
  acquire_lock || { log "another digital-sync run holds the lock (pid $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?')) — skipping"; exit 0; }
fi
trap cleanup EXIT

# ---- clone-mode bootstrap ---------------------------------------------------------
# Not already in the clone → sync it to origin/main and re-exec the CLONE's copy of this
# script, so the running code is always fresh main regardless of the dev checkout's branch
# (this very repo is often on a feature branch). No `npm ci`: the indexer + audio-analyze +
# es-index use only Node built-ins (heavy lifting is ffmpeg/Docker/aws, all system tools).
CLONE_DIR="${POCKETDJ_NIGHTLY_CLONE_DIR-$HOME/.pocketdj/digital-sync-clone}"
if [ -n "$CLONE_DIR" ] && [ "${POCKETDJ_NIGHTLY_IN_CLONE:-0}" != "1" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    log "(dry-run) would sync clone $CLONE_DIR and re-exec from it — continuing in-place"
  else
    ORIGIN="${POCKETDJ_NIGHTLY_ORIGIN:-$("$GIT" -C "$REPO" remote get-url origin)}"
    if [ -d "$CLONE_DIR/.git" ] && ! { "$GIT" -C "$CLONE_DIR" rev-parse --git-dir >/dev/null 2>&1 && [ -f "$CLONE_DIR/scripts/digital-sync-nightly.sh" ]; }; then
      log "⚠ sync clone unhealthy — re-cloning"; rm -rf "$CLONE_DIR"
    fi
    if [ ! -d "$CLONE_DIR/.git" ]; then
      log "creating sync clone at $CLONE_DIR (from $ORIGIN)"
      "$GIT" clone --branch main "$ORIGIN" "$CLONE_DIR" >>"$LOG" 2>&1
    fi
    rm -f "$CLONE_DIR/.git/index.lock"
    "$GIT" -C "$CLONE_DIR" fetch origin main >>"$LOG" 2>&1 || log "⚠ clone fetch failed — proceeding with last-synced clone"
    "$GIT" -C "$CLONE_DIR" checkout -f main >>"$LOG" 2>&1
    "$GIT" -C "$CLONE_DIR" reset --hard origin/main >>"$LOG" 2>&1
    export POCKETDJ_NIGHTLY_IN_CLONE=1 POCKETDJ_NIGHTLY_REPO="$CLONE_DIR"
    log "re-exec from sync clone $CLONE_DIR"
    exec /bin/bash "$CLONE_DIR/scripts/digital-sync-nightly.sh" "$@"
  fi
fi

cd "$REPO"

# SAFE-BY-GUARD: never touch git unless pristine on main (trivially true in clone mode
# after the reset above; still protects an in-place run).
BRANCH="$("$GIT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [ "$BRANCH" != "main" ]; then log "repo on '$BRANCH' (not main) — skipping this run"; exit 0; fi
if [ -n "$("$GIT" status --porcelain)" ]; then log "working tree dirty — skipping this run"; exit 0; fi
run "$GIT" pull --ff-only origin main || { log "git pull failed — skipping this run"; exit 0; }

# ---- preconditions: the burn volume + rip-server must be present -------------------
# The indexer walks $ROOT and POSTs to the rip-server; without either it would ship a
# broken/empty index. Skipping (not failing) means a night with the drive unplugged is a
# harmless no-op that recovers the next night.
if [ ! -d "$ROOT" ] || [ -z "$(ls -A "$ROOT" 2>/dev/null || true)" ]; then
  log "digital root not mounted / empty: $ROOT — skipping this run"; exit 0
fi
if ! curl -sf -m 8 "$RIP_SERVER/health" >/dev/null 2>&1; then
  log "rip-server not reachable at $RIP_SERVER — skipping this run"; exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/digital-nightly.XXXXXX")"   # removed by cleanup EXIT trap

# Deploy S3 index (dev) + record the published (normalized) hash + refresh online search +
# kick a stem backfill for the new songs. Called only after a real change (or a marker
# catch-up). Audio + cover art already reached S3 during the indexer walk.
ship() {
  # Heal a crash between commit and publish: never publish an index whose commit isn't on
  # GitHub (audit trail is load-bearing, GitHub BEFORE S3).
  if [ -n "$("$GIT" rev-list origin/main..HEAD 2>/dev/null)" ]; then
    log "local main ahead of origin — pushing audit trail before publish"
    run "$GIT" push origin main
  fi
  local acct web_bucket
  acct="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
  web_bucket="pocketdj-dev-web-${acct}"
  log "publishing $INDEX -> s3://$web_bucket (CF $CF_DEV)"
  run aws s3 cp "$INDEX" "s3://${web_bucket}/digital-index.json" --profile "$PROFILE" \
    --content-type application/json --cache-control no-cache
  run aws cloudfront create-invalidation --distribution-id "$CF_DEV" --paths /digital-index.json --profile "$PROFILE" >/dev/null
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRYRUN: write publish marker $MARKER" | tee -a "$LOG"
  else
    mkdir -p "$STATE_DIR"; norm_hash "$INDEX" > "$MARKER"
  fi
  # OpenSearch refresh (full reset ~40s; NON-FATAL — catalog is already committed + on S3).
  if [ "${POCKETDJ_SKIP_ES:-0}" != "1" ]; then
    log "refreshing OpenSearch (online search) index…"
    run "$NODE" "$REPO/scripts/es-index.mjs" \
      --endpoint "$ES_ENDPOINT" --index pocketdj --profile "$PROFILE" --region "$REGION" \
      --sources "$ES_SOURCES" \
      || log "⚠ OpenSearch reindex failed (non-fatal) — online search may lag until the next run"
  fi
  # Stem backfill for freshly-ingested songs (background, conc-1, NON-FATAL). No confirmLarge:
  # a candidate set over the server's cap returns needsConfirm and we DON'T force it — that
  # avoids an accidental multi-hour full-corpus stem run; do a big backfill by hand instead.
  if [ "${POCKETDJ_DIGITAL_STEMS:-1}" != "0" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "DRYRUN: POST $RIP_SERVER/backfill-stems" | tee -a "$LOG"
    else
      local sr; sr="$(curl -sS -m 30 -XPOST "$RIP_SERVER/backfill-stems" -H 'content-type: application/json' -d '{}' 2>/dev/null || echo '{"ok":false}')"
      log "stem backfill: $sr"
    fi
  fi
}

# ---- index (incremental: only new album folders do heavy work) --------------------
log "indexing digital root: $ROOT"
COMMITTED_SONGS="$(song_count "$REPO/$INDEX")"
run "$NODE" "$REPO/scripts/index-digital-files.mjs" \
  --root "$ROOT" --env dev --work "$WORK" --rip-server "$RIP_SERVER" --no-publish \
  2>&1 | tee -a "$LOG"

if [ "$DRY_RUN" = 1 ]; then log "(dry-run) stop before change detection / commit"; exit 0; fi

# ---- shrink circuit breaker -------------------------------------------------------
NEW_SONGS="$(song_count "$REPO/$INDEX")"
if [ "$NEW_SONGS" = "0" ] || { [ "$COMMITTED_SONGS" -gt 0 ] && [ "$NEW_SONGS" -lt $(( COMMITTED_SONGS / 2 )) ]; }; then
  if [ "${POCKETDJ_ALLOW_DIGITAL_SHRINK:-0}" != "1" ]; then
    log "⚠ index shrank ($COMMITTED_SONGS → $NEW_SONGS songs) — aborting ship (set POCKETDJ_ALLOW_DIGITAL_SHRINK=1 to override). Reverting working copy."
    "$GIT" checkout -- "$INDEX" 2>/dev/null || true
    exit 1
  fi
  log "index shrank ($COMMITTED_SONGS → $NEW_SONGS songs) but POCKETDJ_ALLOW_DIGITAL_SHRINK=1 — proceeding"
fi

# ---- change detection (generatedAt-independent) -----------------------------------
"$GIT" show "HEAD:$INDEX" > "$TMP/head-index.json" 2>/dev/null || echo '{}' > "$TMP/head-index.json"
if [ "$(norm_hash "$REPO/$INDEX")" = "$(norm_hash "$TMP/head-index.json")" ]; then
  # No catalog change. Revert the generatedAt-only diff so git stays clean…
  "$GIT" checkout -- "$INDEX" 2>/dev/null || true
  # …but if this catalog was never confirmed published (crash after a prior commit), ship it.
  if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$(norm_hash "$REPO/$INDEX")" ]; then
    log "no change — nothing to ship"; exit 0
  fi
  log "no catalog change, but this index isn't confirmed published — publishing (catch-up)"
  ship
  log "shipped (S3/search catch-up)."; exit 0
fi

log "digital catalog changed ($COMMITTED_SONGS → $NEW_SONGS songs) — shipping (GitHub → S3)"
run "$GIT" add "$INDEX"
run "$GIT" commit -m "Digital files: incremental index $(date -u +%FT%TZ)"
ship
log "shipped."
