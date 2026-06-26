# Apple Music (Local) sync — daily + on-demand

Keeps the app's **Apple Music (Local)** data source in step with the Mac's real local
Apple Music library. Two halves:

1. **rip server** (`scripts/rip-server.mjs`, the always-up iMac server): a 04:00 self-check
   + an on-demand `POST /am-sync` endpoint. Reads the library, diffs it with the existing
   incremental indexer, and — when it finds new music — writes a **change-set** to `~/Downloads`.
2. **cron Claude-agent** (`scripts/am-sync-agent.sh` + launchd): watches `~/Downloads`, and for
   each change-set rebuilds the index → commits → pushes to GitHub → deploys to S3.

The native app's **Settings ▸ "Sync Apple Music library"** button drives the same `POST /am-sync`
and shows what was detected instantly.

```
Music.app  ──"Share Library XML"──►  ~/Music/Music/Library.xml
                                          │
rip-server.mjs ──04:00 timer──┐           │ (read + diff via index-apple-music.mjs)
   POST /am-sync → jobId       │           ▼
   GET  /am-sync/<id> → result │   ~/Downloads/pocketdj-am-changeset-<ms>.json  (+ -library-<ms>.xml)
                               │           │
   App (Settings button) ◄─────┘           ├──► cron agent: rebuild → git commit → push → merge → deploy.sh → processed
```

> **Nothing here is live until you activate it** (below). The 04:00 scheduler is gated, the
> launchd job is a `.template`, and the agent is inert scaffolding.

## One-time prerequisites

### 1. Enable the shared Library XML (the freshness requirement)

The server reads `~/Music/Music/Library.xml`, which Music auto-maintains **only when** you turn on:

> **Music ▸ Settings ▸ Advanced ▸ "Share Library XML with other applications"** ✔

With it on, Music rewrites that file as the library changes — fresh enough for a once-daily 04:00
check and the on-demand button. This is a plain file on the boot volume → **no Automation / Full
Disk Access prompt, no removable-volume TCC**. (If the file is absent, the server falls back to
`CFG.libraryXml` = `~/Downloads/Library.xml` and logs a warning.)

### 2. (Agent) a dedicated clone on `main`

The cron agent commits + pushes, so give it its own clone checked out on `main` (NOT a worktree):

```bash
git clone git@levi.github.com:galxy25/pocketdj.git ~/pocketdj-am-agent
( cd ~/pocketdj-am-agent && git checkout main )
```

`jq` is required by the agent: `brew install jq`.

## Activate

### Scheduler (04:00 daily check, in the rip server)

The in-server timer is ON by default — you only need to make sure the server is **not** started
with `POCKETDJ_DISABLE_SCHEDULER=1` (that flag is for tests/dry-runs). Optionally set, when
launching `rip-server.mjs`:

- `POCKETDJ_AM_LIBRARY_XML` — override the library path (default `~/Music/Music/Library.xml`).
- `POCKETDJ_DOWNLOADS_DIR` — where change-sets are written (default `~/Downloads`).
- `POCKETDJ_AM_STATE_DIR` — the machine-local detection cursor (default `~/.pocketdj/am-sync`).

The **first** run seeds the detection cursor to "now" so it does NOT emit the whole ~93k-track
library as "added"; only tracks added after that first run are detected.

### Cron agent (launchd)

```bash
cd ~/pocketdj-am-agent
# Preview first — SAFE: rebuilds into a temp dir to show what WOULD ship, but writes nothing to the
# repo working tree and runs no git commit/push/deploy (every mutating step is echoed, not executed):
POCKETDJ_AGENT_REPO=$PWD scripts/am-sync-agent.sh --dry-run

# Then install the timer (edit the placeholders in the template first):
cp scripts/launchd/com.pocketdj.am-sync-agent.plist.template \
   ~/Library/LaunchAgents/com.pocketdj.am-sync-agent.plist
#   …replace every /Users/REPLACE_ME and confirm PATH has node/aws/claude/jq…
launchctl load ~/Library/LaunchAgents/com.pocketdj.am-sync-agent.plist
# Stop:  launchctl unload ~/Library/LaunchAgents/com.pocketdj.am-sync-agent.plist
```

The agent runs at **04:15** (after the server's 04:00 check) and on any `~/Downloads` change. It
is idempotent: already-processed change-sets (moved to `~/Downloads/pocketdj-am-processed/`) are
skipped, and an empty rebuild diff archives without committing.

## Endpoint + file contracts

**POST `/am-sync`** → `200 { "jobId": "<uuid>", "phase": "queued" }` (returns immediately).

**GET `/am-sync/<id>`**:
```jsonc
{ "jobId":"…","phase":"queued|scanning|diffing|ready|error","message":null,"error":null,
  "result": {                          // null until phase=ready
    "counts": { "added": 12, "changed": 0, "removed": 0 },
    "added":   [ { "songId":"…","albumId":"…","title":"…","artist":"…","change":"added" } ],
    "changed": [], "removed": [],
    "changeSetPath": "/Users/…/Downloads/pocketdj-am-changeset-1750000000000.json"  // null if 0 added
  } }
```

**Change-set** `~/Downloads/pocketdj-am-changeset-<unixms>.json` (schema `pocketdj-am-changeset/1`)
+ sibling snapshot `pocketdj-am-library-<unixms>.xml`. See the `am-sync-deploy` skill for the full
schema. Written only when `added > 0`.

## The detection cursor + the agent's full rebuild (the key decoupling)

- **Detection cursor** — `~/.pocketdj/am-sync/state.json` (machine-local, NOT in the repo). Owned
  by the rip server; advances atomically only after the change-set is durably written. It decides
  *what the server reports as added* and *when to write a change-set*.
- **The agent does a FULL rebuild — no ship cursor.** For each change-set it rebuilds the WHOLE
  index from the change-set's library snapshot (`index-apple-music.mjs --xml <snap> --out <scratch>`,
  **without `--state`** — `--state` would turn the rebuild into a delta and publish a handful of
  tracks over the full catalog). Whether to ship is decided by `git diff`, never a cursor.
- **Catalog-id preservation.** A raw rebuild does not know the ~76k `appleMusicId` storeIds that the
  multi-day resolver crawl (`scripts/resolve-apple-music-catalog.mjs`) bakes into the *committed*
  `public/apple-music-index.json` (its cache ndjson is gitignored + absent in the agent's clone). So
  the agent runs `scripts/am-merge-catalog-ids.mjs --old public/apple-music-index.json --new <scratch>`
  to carry those ids forward before publishing — otherwise every ship would strip streaming
  resolution and fall the whole source back to local-ripping.
- **Deploy-after-push recovery.** If a prior run committed + pushed a change-set but the S3 deploy
  failed, the next rebuild's diff is empty (the index is already committed). The empty-diff guard
  does NOT just archive: it checks `git log --grep="apply changeset <ts>"`, and if that commit
  exists it **re-deploys** from the committed file before consuming, so S3 never lags GitHub. A
  machine-local receipt (`~/.pocketdj/am-last-deployed-blob`, override with `POCKETDJ_AM_AGENT_STATE`)
  records the last confirmed-deployed blob.

The change-set is the audit handoff: the server detects + snapshots, the agent rebuilds + ships.

## Scope / known gaps (v1)

- **`added` only.** The Library.xml diff brain detects new tracks (`Date Added ≥ cursor`); it does
  not itemize `changed`/`removed` (those arrays exist but stay empty). The agent's **full rebuild**
  still reconciles edits/removals into the live catalog on the next run — the catalog converges even
  though the change-set won't list a removal.
- **Future (v2):** a small signed `ITLibrary` Swift helper would give true real-time reads + a real
  `removed` set, at the cost of a bundled signed binary + a media-library permission prompt. Out of
  scope for v1 (kept additive + reversible).

## Dry-run / offline verification

`node scripts/test/am-sync-dryrun.mjs` exercises the whole feature offline (synthetic Library.xml,
a temp Downloads, fake git/deploy/claude) — no live library, no real `~/Downloads`, no GitHub/S3,
and it never touches the running server.
