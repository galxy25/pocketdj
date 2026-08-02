#!/usr/bin/env bash
# PocketDJ Apple-Music-sync agent — consumes the change-sets the rip server writes to
# ~/Downloads and ships the updated "Apple Music (Local)" index. INERT until the user
# installs the launchd timer (scripts/launchd/com.pocketdj.am-sync-agent.plist.template).
#
# For EACH ~/Downloads/pocketdj-am-changeset-<ms>.json (oldest → newest), in this ORDER
# (the ordering is LOAD-BEARING — GitHub audit trail BEFORE the live S3 update):
#     update index  →  git commit  →  git push (GitHub)  →  merge  →  deploy.sh (S3)  →  mark processed
#
# Idempotent + crash-safe:
#   (0) a changeset already in ~/Downloads/pocketdj-am-processed/ is skipped,
#   (1a) an empty `git diff` (the rebuild produced no real change) archives without committing
#        (no empty commit, no prod invalidation),
#   (7)  the changeset + its snapshot are moved to processed ONLY after a fully successful run.
#   GitHub push precedes S3, so a crash between them re-runs and re-deploys from the committed
#   file and converges; a crash before (7) re-runs the same changeset, which (1a) collapses.
#
# Modes:
#   (default)        run the deterministic sequence directly (reliable, testable).
#   --dry-run        print every mutating step WITHOUT committing/pushing/deploying. SAFE preview.
#   --via-claude     delegate each changeset to a headless Claude agent (the am-sync-deploy skill),
#                    which performs the SAME ordered sequence but can reason about merge conflicts.
#
# Overridable commands (so the dry-run harness can shim git/deploy/claude with fakes):
#   POCKETDJ_GIT_CMD, POCKETDJ_DEPLOY_CMD, POCKETDJ_NODE_CMD, POCKETDJ_CLAUDE_CMD, POCKETDJ_JQ_CMD
#   POCKETDJ_AGENT_REPO  — the agent's DEDICATED pocketdj clone on `main` (required unless --dry-run
#                          from inside a clone, where it defaults to this script's repo root).
#   POCKETDJ_DOWNLOADS_DIR — where the change-sets land (default ~/Downloads; override for tests).
#   POCKETDJ_AM_REINDEX_SEARCH=1 — also refresh the OpenSearch index after deploy (default off).
set -euo pipefail

DRY_RUN=0
VIA_CLAUDE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=1 ;;
    --via-claude) VIA_CLAUDE=1 ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_REPO="$(cd "$SELF_DIR/.." && pwd)"
REPO="${POCKETDJ_AGENT_REPO:-$DEFAULT_REPO}"
if [ -z "$REPO" ]; then echo "POCKETDJ_AGENT_REPO must point at the agent's pocketdj clone on main" >&2; exit 2; fi

DL="${POCKETDJ_DOWNLOADS_DIR:-$HOME/Downloads}"
PROCESSED="$DL/pocketdj-am-processed"
GIT="${POCKETDJ_GIT_CMD:-git}"
DEPLOY="${POCKETDJ_DEPLOY_CMD:-$REPO/scripts/deploy.sh}"
NODE="${POCKETDJ_NODE_CMD:-node}"
CLAUDE="${POCKETDJ_CLAUDE_CMD:-claude}"
JQ="${POCKETDJ_JQ_CMD:-jq}"
LOG="${POCKETDJ_AM_AGENT_LOG:-$HOME/.pocketdj/am-sync-agent.log}"

mkdir -p "$PROCESSED" "$(dirname "$LOG")"

log() { echo "[am-sync-agent $(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
# run a MUTATING command — echoed-only under --dry-run, executed otherwise.
run() {
  if [ "$DRY_RUN" = "1" ]; then echo "DRYRUN: $*" | tee -a "$LOG"; else "$@"; fi
}

PUBLIC_INDEX="public/apple-music-index.json"
# write a gitignored local file (the deploy receipt) — echoed-only under --dry-run.
write_file() { if [ "$DRY_RUN" = "1" ]; then echo "DRYRUN: write $1" | tee -a "$LOG"; else printf '%s\n' "$2" > "$1"; fi; }
# the committed index's blob sha of the LAST run we confirmed-deployed (gitignored, machine-local).
RECEIPT_DIR="${POCKETDJ_AM_AGENT_STATE:-$HOME/.pocketdj}"
RECEIPT="$RECEIPT_DIR/am-last-deployed-blob"
mkdir -p "$RECEIPT_DIR" 2>/dev/null || true

process_one() {
  local CS="$1"
  local base TS SNAP
  base="$(basename "$CS")"
  TS="$(echo "$base" | sed -E 's/.*-([0-9]+)\.json/\1/')"

  # (0) already processed → no-op.
  if [ -e "$PROCESSED/$base" ]; then log "skip $base (already processed)"; return 0; fi
  log "processing $base (ts=$TS)"

  if [ "$VIA_CLAUDE" = "1" ]; then
    # Headless Claude does the ordered sequence (reasoning about conflicts). The skill reads
    # $CS + $REPO from the prompt/env. We do NOT mark processed here — the skill does, on success.
    local PROMPT_FILE="$REPO/.claude/skills/am-sync-deploy/PROMPT.txt"
    log "delegating to headless Claude ($PROMPT_FILE)"
    POCKETDJ_CHANGESET="$CS" POCKETDJ_AGENT_REPO="$REPO" \
      run "$CLAUDE" -p "$(cat "$PROMPT_FILE")" --dangerously-skip-permissions \
        --add-dir "$REPO" --add-dir "$DL"
    return 0
  fi

  cd "$REPO"
  SNAP="$("$JQ" -r .librarySnapshot "$CS")"
  if [ -z "$SNAP" ] || [ "$SNAP" = "null" ] || [ ! -e "$SNAP" ]; then
    log "ERROR: snapshot missing for $base (librarySnapshot=$SNAP) — leaving changeset in place"; return 1
  fi

  # Stay current with main before rebuilding (audit-trail base).
  run "$GIT" checkout main
  run "$GIT" pull --ff-only origin main

  # All rebuild outputs go to a per-changeset SCRATCH dir, NOT the repo: the tracked
  # public/apple-music-index.json is touched ONLY by the `run cp` below (skipped under --dry-run),
  # so a preview mutates nothing in the working tree. (index-out/ is gitignored, but writing the
  # full ~93k-track index there each --dry-run would still churn the clone; a temp dir is clean.)
  local SCRATCH; SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/pdj-am-rebuild.XXXXXX")"
  local INDEX_OUT="$SCRATCH/index.json" FINAL="$SCRATCH/final.json"

  # (1) FULL idempotent rebuild from the EXACT snapshot (namespaced Persistent-ID ids → stable).
  # NO --state: --state makes the indexer treat its lastDateAdded as a `since` cursor and emit only
  # a DELTA on the 2nd+ run — which would `cp` a handful-of-tracks index over the full catalog. The
  # agent always wants a deterministic FULL rebuild; the git-diff guard (not a cursor) decides ship.
  log "rebuilding index from snapshot $SNAP → $SCRATCH"
  "$NODE" --max-old-space-size=4096 "$REPO/scripts/index-apple-music.mjs" \
    --xml "$SNAP" --out "$INDEX_OUT"

  # (1b) PRESERVE resolved Apple Music catalog ids. The multi-day iTunes crawl
  # (scripts/resolve-apple-music-catalog.mjs) bakes ~76k `appleMusicId` storeIds straight into the
  # COMMITTED public index; its cache ndjson is gitignored + ABSENT in this clone, so the committed
  # file is the ONLY copy. A raw rebuild drops them all (→ streaming falls back to local-ripping),
  # so merge them forward by song id. First-ever ship (no committed file) → rebuilt index as-is.
  if [ -e "$PUBLIC_INDEX" ]; then
    "$NODE" --max-old-space-size=4096 "$REPO/scripts/am-merge-catalog-ids.mjs" \
      --old "$PUBLIC_INDEX" --new "$INDEX_OUT" --out "$FINAL"
  else
    FINAL="$INDEX_OUT"
  fi

  # (1a) EMPTY-DIFF GUARD: compare the would-be-published FINAL against the committed index WITHOUT
  # writing it (so --dry-run stays non-mutating). No NEW change ⇒ usually archive — BUT a prior run
  # may have committed+pushed this changeset and then FAILED to deploy (crash / S3 hiccup), leaving
  # the changeset un-archived and S3 stale. Detect that via the changeset's unique commit message
  # and RE-DEPLOY from the committed file before consuming, so S3 always converges.
  if "$GIT" diff --no-index --quiet -- "$PUBLIC_INDEX" "$FINAL"; then
    if "$GIT" log -1 --grep="apply changeset $TS\$" --format=%H 2>/dev/null | grep -q .; then
      log "changeset $TS already committed but not confirmed-deployed — re-deploying then archiving"
      run "$DEPLOY" dev
      run "$DEPLOY" prod
      write_file "$RECEIPT" "$("$GIT" rev-parse "HEAD:public/apple-music-index.json" 2>/dev/null || echo unknown)"
    else
      log "no index change for $base — archiving (empty-diff guard)"
    fi
    run mv "$CS" "$PROCESSED"/
    [ -e "$SNAP" ] && run mv "$SNAP" "$PROCESSED"/ || true
    rm -rf "$SCRATCH"
    return 0
  fi

  # SHRINK GUARD. A rebuild from one snapshot can only ever see what Music.app's XML export
  # contains, so it silently omits subscription-only rows, video rows and every folded
  # share-link column that the committed index accumulated from other pipelines. Since the next
  # two lines cp → commit → push → deploy to S3, one stale-snapshot run would wipe that from
  # GitHub and production simultaneously. Refuse to publish an index that LOSES songs, and
  # refuse to drop rows the union stamped as subscription-only.
  if [ -e "$PUBLIC_INDEX" ] && [ "$DRY_RUN" != 1 ]; then
    if ! "$NODE" -e '
      const fs=require("fs");
      const cur=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const next=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
      const nextIds=new Set((next.songs||[]).map(s=>s.id));
      const lostSub=(cur.songs||[]).filter(s=>s.librarySource==="subscription"&&!nextIds.has(s.id)).length;
      const d=(cur.songs||[]).length-(next.songs||[]).length;
      if(d>0||lostSub>0){
        console.error(`✗ rebuild SHRINKS the catalog (${(cur.songs||[]).length} → ${(next.songs||[]).length}`+
          `, subscription rows lost: ${lostSub}) — refusing to publish. The snapshot is probably stale;`+
          ` re-export the library, or reconcile with scripts/union-am-index.mjs.`);
        process.exit(1);
      }' "$PUBLIC_INDEX" "$FINAL"; then
      log "SHRINK GUARD tripped for $base — leaving changeset unconsumed for a human"
      rm -rf "$SCRATCH"
      return 1
    fi
  fi

  # publish: cp is the FIRST tracked-tree write (skipped under --dry-run).
  run cp "$FINAL" "$PUBLIC_INDEX"
  # (2) COMMIT
  run "$GIT" add "$PUBLIC_INDEX"
  run "$GIT" commit -m "Apple Music sync: apply changeset $TS"
  # (3) PUSH GitHub — AUDIT TRAIL FIRST, before any S3 write.
  run "$GIT" push origin main
  # (4) MERGE — direct-on-main here (already on main); a branch flow would `git merge --no-ff`
  #     into main then push. Kept explicit so the load-bearing ordering is documented.
  # (5) DEPLOY S3 — only AFTER GitHub has the commit.
  run "$DEPLOY" dev
  run "$DEPLOY" prod
  # record the deployed blob so a re-run after a deploy-only failure can tell "already shipped".
  write_file "$RECEIPT" "$("$GIT" rev-parse "HEAD:public/apple-music-index.json" 2>/dev/null || echo unknown)"
  # (6) OPTIONAL search refresh (non-fatal, opt-in).
  if [ "${POCKETDJ_AM_REINDEX_SEARCH:-0}" = "1" ]; then
    run "$NODE" "$REPO/scripts/es-index.mjs" \
      --sources "$REPO/public/current-index.json,$REPO/public/apple-music-index.json,$REPO/public/digital-index.json" \
      --profile levi --region us-west-2 || log "search reindex failed (non-fatal)"
  fi
  # (7) MARK CONSUMED — only after full success.
  run mv "$CS" "$PROCESSED"/
  [ -e "$SNAP" ] && run mv "$SNAP" "$PROCESSED"/ || true
  rm -rf "$SCRATCH"
  log "done $base"
}

shopt -s nullglob
CHANGESETS=("$DL"/pocketdj-am-changeset-*.json)
if [ ${#CHANGESETS[@]} -eq 0 ]; then log "no change-sets in $DL"; exit 0; fi

# Oldest → newest (the unixms in the name sorts lexically for a fixed digit count; `sort` is
# belt-and-suspenders).
IFS=$'\n' SORTED=($(printf '%s\n' "${CHANGESETS[@]}" | sort)); unset IFS
for CS in "${SORTED[@]}"; do
  process_one "$CS" || log "FAILED $CS (left in place for the next run)"
done
