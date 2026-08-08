#!/usr/bin/env bash
# PocketDJ "streaming links" nightly backfill (F3 "Sharing") — derive each song/album's Apple
# Music deep-link from its appleMusicId, then browser-resolve a nightly BATCH of Spotify +
# YouTube canonical links, fold both into the catalog indexes, and ship.
#
# Sibling of scripts/digital-sync-nightly.sh — same robustness skeleton: a dedicated always-on-
# main clone, single-instance lock, GitHub-commit-BEFORE-S3 ordering, and a normalized-hash
# change gate. The "work" here is: (1) fold-apple-music-links (free, id-derived), (2) an
# INCREMENTAL, resumable headless-Chromium resolve of the next $BATCH un-resolved songs into a
# PERSISTENT ndjson cache that lives OUTSIDE the reset --hard'd clone, (3) fold-streaming-links.
#
# Runs at 06:00 — one hour after the 05:00 digital-sync-nightly (and two after the 04:00 Apple
# Music nightly) so they never contend for the git clone lock or the deploy pipeline.
#
# The full ~94k-song catalog resolves at ~14 songs/min, so a single night can only chip away a
# batch; the resumable cache means each night continues where the last stopped and the catalog
# fills in over ~1-2 weeks of nightly runs (or a one-shot manual full run — see the note in
# scripts/install-streaming-links-nightly.sh).
#
# Overridable for tests/dry-run:
#   POCKETDJ_LINK_INDEXES  — comma list of --index specs to resolve (default "apple-music").
#   POCKETDJ_LINK_BATCH    — songs to resolve per index per night (default 800; ~1h).
#   POCKETDJ_LINK_SERVICES — services to resolve (default "spotify,youtube").
#   POCKETDJ_LINK_CACHE    — persistent ndjson cache path (default ~/.pocketdj/streaming-links/links-cache.ndjson).
#   POCKETDJ_NIGHTLY_CLONE_DIR — sync-clone path; set EMPTY to run in-place.
#   POCKETDJ_NIGHTLY_REPO / _ORIGIN — repo + clone URL (default: this script's repo).
#   POCKETDJ_NODE_CMD / POCKETDJ_GIT_CMD — shim the tools.
#   --dry-run — print every mutating step WITHOUT cloning/resolving/committing/publishing.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${POCKETDJ_NIGHTLY_REPO:-$(cd "$SELF_DIR/.." && pwd)}"
NODE="${POCKETDJ_NODE_CMD:-node}"
GIT="${POCKETDJ_GIT_CMD:-git}"
LOG="${POCKETDJ_NIGHTLY_LOG:-$HOME/.pocketdj/streaming-links-nightly.log}"
STATE_DIR="$HOME/.pocketdj/streaming-links"
CACHE="${POCKETDJ_LINK_CACHE:-$STATE_DIR/links-cache.ndjson}"
LINK_INDEXES="${POCKETDJ_LINK_INDEXES:-apple-music}"
LINK_BATCH="${POCKETDJ_LINK_BATCH:-800}"
LINK_SERVICES="${POCKETDJ_LINK_SERVICES:-spotify,youtube}"
PROFILE="${AWS_PROFILE:-levi}"
# Per-index CDN home (mirrors deploy.sh:77-78): vinyl + Apple Music → PROD, My Digital → DEV.
CF_DEV="E123GKAO9JVETP"
CF_PROD="E1SP8M1SIF7Q8D"
# The published documents this pipeline can touch: the three catalog indexes plus the
# recommendation-engine feature file DERIVED from them (stage 4) — the rec Lambda scores
# against the CDN copy, so every index change must carry the derived file with it or the
# engine drifts against a stale snapshot.
PUBLISH_INDEXES=("public/current-index.json" "public/apple-music-index.json" "public/digital-index.json" "public/rec-features.json")

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1
mkdir -p "$(dirname "$LOG")"
log() { echo "[streaming-links-nightly $(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
run() { if [ "$DRY_RUN" = 1 ]; then echo "DRYRUN: $*" | tee -a "$LOG"; else "$@"; fi; }

# Normalized index hash — IGNORES manifest.generatedAt AND a root-level generatedAt
# (rec-features.json stamps the latter), so an unchanged document compares equal
# night-to-night. Prints "ERR" on a missing/corrupt file (never a false match).
norm_hash() {
  "$NODE" -e '
    const fs=require("fs"),crypto=require("crypto");
    try{const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      if(j&&j.manifest)delete j.manifest.generatedAt;
      if(j)delete j.generatedAt;
      process.stdout.write(crypto.createHash("sha256").update(JSON.stringify(j)).digest("hex"));
    }catch(e){process.stdout.write("ERR")}' "$1"
}
# Which env's bucket/distribution serves a given index basename. rec-features.json is PROD:
# the rec-engine Lambda's FEATURES_URL points at the prod CloudFront (see
# scripts/lambda/rec-engine/deploy.sh).
index_env() {
  case "$(basename "$1")" in
    current-index.json|apple-music-index.json|rec-features.json) echo prod ;;
    digital-index.json) echo dev ;;
    *) echo "" ;;
  esac
}

# Single-instance lock (mkdir is atomic; macOS has no flock).
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
  acquire_lock || { log "another streaming-links run holds the lock (pid $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?')) — skipping"; exit 0; }
fi
trap cleanup EXIT

# ---- clone-mode bootstrap ---------------------------------------------------------
# Sync a dedicated clone to origin/main and re-exec the CLONE's copy, so the running code is
# always fresh main regardless of the dev checkout's branch. The PERSISTENT link cache lives
# under $STATE_DIR (outside the clone), so a reset --hard never discards resolved links.
CLONE_DIR="${POCKETDJ_NIGHTLY_CLONE_DIR-$HOME/.pocketdj/streaming-links-clone}"
if [ -n "$CLONE_DIR" ] && [ "${POCKETDJ_NIGHTLY_IN_CLONE:-0}" != "1" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    log "(dry-run) would sync clone $CLONE_DIR and re-exec from it — continuing in-place"
  else
    ORIGIN="${POCKETDJ_NIGHTLY_ORIGIN:-$("$GIT" -C "$REPO" remote get-url origin)}"
    if [ -d "$CLONE_DIR/.git" ] && ! { "$GIT" -C "$CLONE_DIR" rev-parse --git-dir >/dev/null 2>&1 && [ -f "$CLONE_DIR/scripts/streaming-links-nightly.sh" ]; }; then
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
    # The resolver needs Playwright + Chromium; the clone has no node_modules. `npm ci` here keeps
    # the clone self-contained (Chromium is cached under ~/Library/Caches/ms-playwright).
    if [ ! -d "$CLONE_DIR/node_modules/playwright" ]; then
      log "installing node deps in clone (playwright)…"
      ( cd "$CLONE_DIR" && npm ci >>"$LOG" 2>&1 ) || log "⚠ npm ci failed — resolve stage may fail"
    fi
    export POCKETDJ_NIGHTLY_IN_CLONE=1 POCKETDJ_NIGHTLY_REPO="$CLONE_DIR"
    log "re-exec from sync clone $CLONE_DIR"
    exec /bin/bash "$CLONE_DIR/scripts/streaming-links-nightly.sh" "$@"
  fi
fi

cd "$REPO"

# SAFE-BY-GUARD: never touch git unless pristine on main (trivially true in clone mode).
BRANCH="$("$GIT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [ "$BRANCH" != "main" ]; then log "repo on '$BRANCH' (not main) — skipping this run"; exit 0; fi
if [ -n "$("$GIT" status --porcelain)" ]; then log "working tree dirty — skipping this run"; exit 0; fi
run "$GIT" pull --ff-only origin main || { log "git pull failed — skipping this run"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/streaming-links-nightly.XXXXXX")"   # removed by cleanup EXIT trap
mkdir -p "$(dirname "$CACHE")"

# ---- stage 1: Apple Music links (free, id-derived) --------------------------------
log "stage 1: fold Apple Music links (appleMusicId → appleMusicUrl)"
run "$NODE" "$REPO/scripts/fold-apple-music-links.mjs" --apply 2>&1 | tee -a "$LOG"

# ---- stage 2: browser-resolve a batch of Spotify + YouTube links ------------------
# Resumable: the persistent cache means each night continues the crawl. One --index per call.
IFS=',' read -ra IDXS <<< "$LINK_INDEXES"
for spec in "${IDXS[@]}"; do
  spec="$(echo "$spec" | xargs)"; [ -z "$spec" ] && continue
  log "stage 2: resolve up to $LINK_BATCH songs on '$spec' (services=$LINK_SERVICES) → $CACHE"
  run "$NODE" "$REPO/scripts/resolve-streaming-links.mjs" \
    --index "$spec" --limit "$LINK_BATCH" --services "$LINK_SERVICES" --cache "$CACHE" 2>&1 | tee -a "$LOG"
done

# ---- stage 3: fold the resolved links into the catalog indexes --------------------
log "stage 3: fold resolved Spotify/YouTube links into the indexes"
run "$NODE" "$REPO/scripts/fold-streaming-links.mjs" --apply --cache "$CACHE" 2>&1 | tee -a "$LOG"

# ---- stage 4: regenerate the rec-engine feature file from the (possibly updated) indexes
# Derived, deterministic, cheap (~seconds); the change gate below ships it only when its
# normalized content actually moved. Soft-fail: a regen bug must not block the link fold.
log "stage 4: regenerate public/rec-features.json (rec-engine feature file)"
run "$NODE" "$REPO/scripts/build-rec-features.mjs" 2>&1 | tee -a "$LOG" \
  || log "⚠ rec-features regeneration failed — keeping the committed copy"

if [ "$DRY_RUN" = 1 ]; then log "(dry-run) stop before change detection / commit / publish"; exit 0; fi

# ---- change detection → commit (GitHub) → publish (S3) ----------------------------
# Collect the indexes that actually changed (generatedAt-independent), commit them, push the
# audit trail FIRST, THEN publish each changed index to its home bucket + invalidate.
CHANGED=()
for rel in "${PUBLISH_INDEXES[@]}"; do
  [ -f "$REPO/$rel" ] || continue
  "$GIT" show "HEAD:$rel" > "$TMP/head.json" 2>/dev/null || echo '{}' > "$TMP/head.json"
  if [ "$(norm_hash "$REPO/$rel")" != "$(norm_hash "$TMP/head.json")" ]; then
    CHANGED+=("$rel")
  else
    "$GIT" checkout -- "$rel" 2>/dev/null || true   # drop a generatedAt-only diff
  fi
done

if [ "${#CHANGED[@]}" -eq 0 ]; then log "no link changes — nothing to ship"; exit 0; fi

log "links changed in: ${CHANGED[*]} — committing (GitHub → S3)"
for rel in "${CHANGED[@]}"; do "$GIT" add "$rel"; done
"$GIT" commit -m "Streaming links: nightly backfill $(date -u +%FT%TZ)"
# GitHub BEFORE S3 (audit trail is load-bearing).
if [ -n "$("$GIT" rev-list origin/main..HEAD 2>/dev/null)" ]; then
  log "pushing audit trail before publish"
  "$GIT" push origin main
fi

acct="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
declare -a INV_PROD=() INV_DEV=()
for rel in "${CHANGED[@]}"; do
  env="$(index_env "$rel")"; [ -z "$env" ] && continue
  bucket="pocketdj-${env}-web-${acct}"
  name="$(basename "$rel")"
  log "publishing $name -> s3://$bucket/$name [$env]"
  aws s3 cp "$REPO/$rel" "s3://${bucket}/${name}" --profile "$PROFILE" \
    --content-type application/json --cache-control no-cache --only-show-errors
  if [ "$env" = prod ]; then INV_PROD+=("/$name"); else INV_DEV+=("/$name"); fi
done
[ "${#INV_PROD[@]}" -gt 0 ] && aws cloudfront create-invalidation --distribution-id "$CF_PROD" --paths "${INV_PROD[@]}" --profile "$PROFILE" >/dev/null 2>&1 || true
[ "${#INV_DEV[@]}"  -gt 0 ] && aws cloudfront create-invalidation --distribution-id "$CF_DEV"  --paths "${INV_DEV[@]}"  --profile "$PROFILE" >/dev/null 2>&1 || true
log "shipped."
