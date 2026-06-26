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

INDEX_OUT="index-out/apple-music/index.json"
STATE_OUT="index-out/apple-music/state.json"
PUBLIC_INDEX="public/apple-music-index.json"

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

  # (1) FULL idempotent rebuild from the EXACT snapshot (namespaced Persistent-ID ids → stable).
  log "rebuilding index from snapshot $SNAP"
  "$NODE" --max-old-space-size=4096 "$REPO/scripts/index-apple-music.mjs" \
    --xml "$SNAP" --out "$INDEX_OUT" --state "$STATE_OUT"
  cp "$INDEX_OUT" "$PUBLIC_INDEX"

  # (1a) EMPTY-DIFF GUARD: no real change ⇒ archive + stop (no empty commit / no prod invalidation).
  if "$GIT" diff --quiet -- "$PUBLIC_INDEX"; then
    log "no index change for $base — archiving (empty-diff guard)"
    run mv "$CS" "$PROCESSED"/
    [ -e "$SNAP" ] && run mv "$SNAP" "$PROCESSED"/ || true
    return 0
  fi

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
  # (6) OPTIONAL search refresh (non-fatal, opt-in).
  if [ "${POCKETDJ_AM_REINDEX_SEARCH:-0}" = "1" ]; then
    run "$NODE" "$REPO/scripts/es-index.mjs" \
      --sources "$REPO/public/current-index.json,$REPO/public/apple-music-index.json" \
      --profile levi --region us-west-2 || log "search reindex failed (non-fatal)"
  fi
  # (7) MARK CONSUMED — only after full success.
  run mv "$CS" "$PROCESSED"/
  [ -e "$SNAP" ] && run mv "$SNAP" "$PROCESSED"/ || true
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
