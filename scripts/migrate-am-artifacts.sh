#!/usr/bin/env bash
# Move the Apple Music sync's audit artifacts out of ~/Downloads and into ~/Documents/PocketDJ.
#
# STAGE A of the retention change: this script MOVES, it never deletes. Everything it touches
# ends up somewhere else on the same volume, so the whole thing is reversible by moving it back.
# Deletion of the proven-duplicate snapshots is STAGE C, a separate explicit command.
#
# WHAT IT DOES NOT TOUCH — all verified live on this machine:
#   ~/Downloads/Library.xml            the user's manual Music.app export. NOT indexer output.
#                                      ~/Music/Music/Library.xml does not exist, so this is the
#                                      only one, and it has four live readers (rip-server's
#                                      warmLibIndex + /am-sync fallback, rip-one.mjs,
#                                      reindex-cloud-analysis.mjs — the last has no env override).
#   djpocketsearch-credentials.json    not ours
#   pocketdj-server-checklist.md       not ours
#
# Usage:  scripts/migrate-am-artifacts.sh [--apply]      (default: dry run)
set -euo pipefail

DL="${POCKETDJ_DOWNLOADS_DIR:-$HOME/Downloads}"
ROOT="${POCKETDJ_AM_ARTIFACT_DIR:-$HOME/Documents/PocketDJ}"
SNAPS="${POCKETDJ_AM_SNAPSHOT_DIR:-$ROOT/snapshots.nosync}"
PROCESSED="$ROOT/processed"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

say() { printf '%s\n' "$*"; }
run() { if [ "$APPLY" = 1 ]; then "$@"; else say "  DRY: $*"; fi; }

say "source: $DL"
say "target: $ROOT  (snapshots → $SNAPS)"
[ "$APPLY" = 1 ] || say "DRY RUN — pass --apply to actually move"
say ""

run mkdir -p "$ROOT" "$SNAPS" "$PROCESSED"

# --- Snapshots -------------------------------------------------------------------------------
# Keep the NEWEST one and move it; the rest are left in place for stage C to delete after their
# duplicate-ness has been re-proven. Moving only the keeper means a mistake here costs nothing.
mapfile -t SNAPFILES < <(ls -1 "$DL"/pocketdj-am-library-*.xml 2>/dev/null | sort -t- -k4 -n || true)
if [ "${#SNAPFILES[@]}" -gt 0 ]; then
  NEWEST="${SNAPFILES[-1]}"
  say "snapshots: ${#SNAPFILES[@]} found; keeping $(basename "$NEWEST")"
  run mv "$NEWEST" "$SNAPS/"
  # Stamp the sidecar so the server's reuse check is O(1) and the next sync copies nothing.
  if [ "$APPLY" = 1 ]; then
    shasum -a 256 "$SNAPS/$(basename "$NEWEST")" | awk '{print $1}' > "$SNAPS/$(basename "$NEWEST").sha256"
  else
    say "  DRY: write $SNAPS/$(basename "$NEWEST").sha256"
  fi
  say "  ${#SNAPFILES[@]} snapshot(s) total; $(( ${#SNAPFILES[@]} - 1 )) older left in $DL for stage C"
else
  say "snapshots: none"
fi

# --- Change-sets -----------------------------------------------------------------------------
# All of them move: they are ~230 KB each and they ARE the "what did that sync do" record.
COUNT=0
for f in "$DL"/pocketdj-am-changeset-*.json; do
  [ -e "$f" ] || continue
  run mv "$f" "$ROOT/"
  COUNT=$((COUNT + 1))
done
say "change-sets: $COUNT moved"

# --- Processed ledger ------------------------------------------------------------------------
if [ -d "$DL/pocketdj-am-processed" ]; then
  N=$(find "$DL/pocketdj-am-processed" -type f | wc -l | tr -d ' ')
  say "processed ledger: $N file(s) → $PROCESSED"
  for f in "$DL"/pocketdj-am-processed/*; do
    [ -e "$f" ] || continue
    run mv "$f" "$PROCESSED/"
  done
  run rmdir "$DL/pocketdj-am-processed"
fi

# --- Repoint the ACTIVE change-sets at the moved snapshot -------------------------------------
# Each change-set pins `librarySnapshot` as an ABSOLUTE path and a consumer hard-fails on a
# missing one, so the pointers must be updated after the move.
#
# ONLY the active ones, and ONLY when their target is really gone. An earlier version rewrote
# every change-set including the archived ones, which did two bad things: it made the June
# archive claim an August export it was never generated against, and — because the retention
# pin is "a snapshot some change-set still names" — it un-pinned the June snapshots and let the
# next sweep delete them. Archived change-sets whose snapshot is missing are marked as such
# rather than pointed somewhere false: a wrong pointer is worse than an absent one.
if [ "$APPLY" = 1 ] && [ "${#SNAPFILES[@]}" -gt 0 ]; then
  KEPT="$SNAPS/$(basename "${SNAPFILES[-1]}")"
  node -e '
    const {readdirSync,readFileSync,writeFileSync,existsSync}=require("fs"),{join}=require("path");
    const [root,kept]=process.argv.slice(1); let n=0, m=0;
    // ACTIVE: these correspond to the retained (newest) snapshot — repoint them.
    for (const f of readdirSync(root)) {
      if (!/^pocketdj-am-changeset-\d+\.json$/.test(f)) continue;
      const p=join(root,f); const d=JSON.parse(readFileSync(p,"utf8"));
      if (d.librarySnapshot && d.librarySnapshot !== kept && !existsSync(d.librarySnapshot)) {
        d.librarySnapshot = kept; writeFileSync(p, JSON.stringify(d,null,2)); n++;
      }
    }
    // ARCHIVED: leave the pointer alone if the snapshot survived the move; otherwise say so.
    const pd = join(root,"processed");
    if (existsSync(pd)) for (const f of readdirSync(pd)) {
      if (!/^pocketdj-am-changeset-\d+\.json$/.test(f)) continue;
      const p=join(pd,f); const d=JSON.parse(readFileSync(p,"utf8"));
      if (d.librarySnapshot && !existsSync(d.librarySnapshot)) {
        d.librarySnapshotMissing = d.librarySnapshot; d.librarySnapshot = null;
        writeFileSync(p, JSON.stringify(d,null,2)); m++;
      }
    }
    console.log(`  repointed ${n} active change-set(s) at ${kept}; flagged ${m} archived as snapshot-missing`);
  ' "$ROOT" "$KEPT"
fi

say ""
say "done. Nothing was deleted."
