---
name: am-sync-deploy
description: Ship a PocketDJ Apple-Music-sync change-set — rebuild the "Apple Music (Local)" index from the change-set's library snapshot, COMMIT + PUSH to GitHub (audit trail FIRST), merge to main, then deploy to S3, and mark the change-set processed. Triggers when the am-sync-agent invokes a headless Claude run for a ~/Downloads/pocketdj-am-changeset-*.json. Order is load-bearing: GitHub BEFORE S3.
---

# am-sync-deploy

Consume ONE change-set written by the rip server's AM-sync (`~/Downloads/pocketdj-am-changeset-<ms>.json`)
and ship the updated `Apple Music (Local)` index. This is the cron Claude-agent half of the daily
+ on-demand sync (the rip server detects new music + writes the change-set; this skill rebuilds +
publishes it). Reuses the **apple-music-indexer** (rebuild) and **publish-s3** (deploy) flows.

## Inputs (env)

- `POCKETDJ_CHANGESET` — absolute path of the one change-set to process.
- `POCKETDJ_AGENT_REPO` — the agent's dedicated pocketdj clone, checked out on `main`.
- `POCKETDJ_DOWNLOADS_DIR` — defaults to `~/Downloads`; processed files move to `…/pocketdj-am-processed/`.

## Change-set shape (`pocketdj-am-changeset/1`)

```jsonc
{
  "schema": "pocketdj-am-changeset/1",
  "ts": 1750000000000,
  "librarySnapshot": "/Users/…/Downloads/pocketdj-am-library-1750000000000.xml", // rebuild from THIS
  "librarySnapshotSha256": "<hex>",
  "since": "<ISO cursor at detection time>",
  "counts": { "added": 12, "changed": 0, "removed": 0, "albumsTouched": 5, "playlists": 126 },
  "added":   [ { "songId":"sng_…","albumId":"alb_…","title":"…","artist":"…","album":"…","trackNumber":3,"appleMusicId":null } ],
  "changed": [], "removed": []
}
```

The change-set is the **handoff + audit record**. Rebuild from `librarySnapshot` (the EXACT XML
captured at detection time), NOT from Music's live state — so the deploy is deterministic and
decoupled from whatever the library holds at cron time. Optionally verify `librarySnapshotSha256`.

## The ordered sequence (ORDER IS LOAD-BEARING — GitHub BEFORE S3)

Run from `$POCKETDJ_AGENT_REPO`. `CS=$POCKETDJ_CHANGESET`, `TS` = the `ts` from the filename,
`PROCESSED=$DL/pocketdj-am-processed`.

```bash
set -euo pipefail
cd "$REPO"
# (0) already processed? → no-op.
[ -e "$PROCESSED/$(basename "$CS")" ] && exit 0
git checkout main && git pull --ff-only origin main
SNAP="$(jq -r .librarySnapshot "$CS")"
[ -e "$SNAP" ] || { echo "snapshot missing"; exit 1; }

# (1) FULL idempotent rebuild from the snapshot (namespaced Persistent-ID ids → stable across runs).
# NO --state: with --state the indexer treats its lastDateAdded as a `since` cursor and emits only a
# DELTA on the 2nd+ run — which would publish a handful-of-tracks index over the full ~93k catalog.
# The agent always wants a full rebuild; the git-diff guard (not a cursor) decides whether to ship.
SCRATCH="$(mktemp -d)"
node --max-old-space-size=4096 scripts/index-apple-music.mjs --xml "$SNAP" --out "$SCRATCH/index.json"

# (1b) PRESERVE resolved Apple Music catalog ids. The multi-day iTunes crawl
# (scripts/resolve-apple-music-catalog.mjs) bakes ~76k `appleMusicId` storeIds straight into the
# COMMITTED public/apple-music-index.json; its cache ndjson is gitignored + ABSENT in this clone, so
# the committed file is the ONLY copy. A raw rebuild drops every one (→ streaming falls back to
# local-ripping), so merge them forward by song id before publishing.
node --max-old-space-size=4096 scripts/am-merge-catalog-ids.mjs \
  --old public/apple-music-index.json --new "$SCRATCH/index.json" --out "$SCRATCH/final.json"
cp "$SCRATCH/final.json" public/apple-music-index.json

# (1a) EMPTY-DIFF GUARD — no real change ⇒ archive + stop (no empty commit, no prod invalidation).
# RECOVERY: if a PRIOR run committed+pushed THIS changeset but then failed to deploy, the diff is
# empty yet S3 is stale. If `git log -1 --grep="apply changeset $TS\$"` finds the commit, RE-DEPLOY
# (scripts/deploy.sh dev && prod) before archiving — never leave S3 behind the audit trail.
if git diff --quiet -- public/apple-music-index.json; then
  mv "$CS" "$PROCESSED"/; mv "$SNAP" "$PROCESSED"/ 2>/dev/null || true; exit 0
fi

# (2) COMMIT
git add public/apple-music-index.json
git commit -m "Apple Music sync: apply changeset $TS"
# (3) PUSH GitHub — AUDIT TRAIL FIRST, before any S3 write (remote: git@levi.github.com).
git push origin main
# (4) MERGE — direct-on-main here; a branch flow merges --no-ff into main then pushes origin main.
# (5) DEPLOY S3 — only AFTER GitHub has the commit.
scripts/deploy.sh dev
scripts/deploy.sh prod
# (6) OPTIONAL search refresh (non-fatal) — see es-search-index skill.
node scripts/es-index.mjs --sources public/current-index.json,public/apple-music-index.json \
  --profile levi --region us-west-2 || true
# (7) MARK CONSUMED — only after full success.
mv "$CS" "$PROCESSED"/; mv "$SNAP" "$PROCESSED"/ 2>/dev/null || true
```

## Why this order + idempotency

- **GitHub before S3**: there is always a committed audit trail of exactly what went live, BEFORE
  the live catalog changes. A crash after push / before deploy leaves GitHub ahead → the next run's
  rebuild diff is now EMPTY (the index is already committed), so the empty-diff guard's RECOVERY
  branch (the `git log --grep` check above) re-deploys from the committed file and converges — it
  does NOT silently archive a still-undeployed changeset. A crash before `git push` re-runs the
  rebuild, which (1a) collapses to a no-op if nothing changed.
- **Full rebuild, not a delta apply**: the index is idempotent by namespaced Persistent-ID sha, so
  re-running is safe; a removed/edited track is reconciled (omitted/updated) on the next rebuild even
  though v1 change-sets only itemize `added`.
- **Never double-apply**: the `(0)` processed pre-check + the `(7)` consume-marker (only on success)
  make re-runs no-ops.

## Conflict handling (why a Claude agent, not just a shell)

If `git pull --ff-only` or `git push` reports the remote moved (a human pushed meanwhile), do NOT
force. Re-pull, re-run the rebuild from the same snapshot (idempotent), re-commit, and push again.
If the working tree has unexpected uncommitted changes to `public/apple-music-index.json` that are
NOT this rebuild, STOP and leave the change-set in place for human review rather than clobbering.

`scripts/am-sync-agent.sh` (default mode) performs this exact sequence deterministically; the
`--via-claude` mode runs THIS skill so the agent can reason about the conflict cases above.
