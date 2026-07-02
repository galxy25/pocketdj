# Chapter 7 — Distribution, Clients & the Edits Round-Trip

> Part of the [PocketDJ Architecture Book](../ARCHITECTURE.md). Prereq:
> [Ch. 1 Foundations](./01-foundations.md). This pillar delivers **"Portable…
> anyone, anywhere"** — how the produced artifacts reach a phone, how the thin
> clients consume them, and how user corrections get back home.

---

## 1. AWS S3 / CloudFront — the public content host

**Why.** Clients must work **offline-first, anywhere, with zero running server**. A
static, public, globally-cached origin is the cheapest, most durable way to serve the
catalog, ~1,160 cover thumbnails, the PWA shell, and the audio cache. CloudFront adds
the **HTTPS** a PWA service worker mandates and a same-origin **proxy** for OpenSearch
(Ch. 6).

| Bucket | Key objects | Written by | Read by |
|---|---|---|---|
| **web** `pocketdj-{dev,prod}-web-<acct>` | `current-index.json`, `apple-music-index.json`, `index.html` + hashed assets + `sw.js`, `/art/*`, `/lyrics/*` | `deploy.sh`, `mirror-art.sh` (profile `levi`) | all clients (via CloudFront) |
| **rips** `pocketdj-rips-011183829623` | `rips/manifest.json`, `rips/<id>.mp3`, `rips/waveforms/<id>.png` | `rip-server.mjs`, `rip-one.mjs` (profile `levi`) | all clients (direct S3 https) |

```
   Anyone on the internet            Only the iMac (levi IAM creds)
        │  GET                              │  PUT / sync / invalidate
        ▼                                   ▼
   ┌─────────────────────────┐      ┌─────────────────────────┐
   │ s3:GetObject  Allow *   │      │ s3:PutObject (levi only)│
   │ (bucket policy)         │      │ cloudfront:Create-      │
   │  → public-read          │      │   Invalidation (levi)   │
   └─────────────────────────┘      └─────────────────────────┘
   web bucket  ── CloudFront ── HTTPS ──▶ clients     rips bucket ──▶ clients
   dev:  djictbz9w796r.cloudfront.net   (E123GKAO9JVETP)
   prod: d2p4cubg6se03u.cloudfront.net  (E1SP8M1SIF7Q8D)
```

**Reading the diagram.** The left box is the **public-read** grant
(`Allow * s3:GetObject`) — why a phone can stream a ripped mp3 with the rip server off
and seed a catalog with no auth. The right box is **private-write**: only the `levi`
principal can `s3:PutObject` / `cloudfront:CreateInvalidation`, so all mutation
funnels through the iMac. The two named CloudFront distributions (dev `E123GKAO9JVETP`,
prod `E1SP8M1SIF7Q8D`) front the **web** bucket; the **rips** bucket is reached at its
raw S3 https URL (no CloudFront).

**Cache tiers & SPA fallback (`deploy.sh`):**
- Hashed `assets/*` → `public,max-age=31536000,immutable`.
- `index.html`, `sw.js`, `registerSW.js`, `manifest.webmanifest`,
  `current-index.json`, **`apple-music-index.json`** → `no-cache` (the
  `NOCACHE` list — auto-updating SW + both seed catalogs always revalidate).
  `apple-music-index.json` is no-cache because it's refreshed **incrementally** by the
  multi-day catalog-id resolver crawl (Ch. 3 §1.1) and fetched at runtime from
  CloudFront by the native app — immutable caching would pin clients to a stale,
  under-resolved copy for a year.
- `--delete` on sync **excludes `art/*` and `lyrics/*`** so a deploy never wipes those
  separately-uploaded caches.
- CloudFront custom error responses map 403/404 → `/index.html` (200) so client
  routes like `/map/:albumId` resolve.
- A CloudFront **behavior** forwards `/pocketdj/*` to the aoss origin (Ch. 6).

**How (worked example): a cover goes offline-durable.** `mirror-art.sh` uploads
`art/alb_4f2c91ab7d10.jpg` (`image/jpeg, immutable`). The album's `coverArtSources`
now lead with `{type:"cdn", url:"/art/alb_4f2c91ab7d10.jpg", cors:true}`. The client
prefers the cdn/cors source, fetches it same-origin via CloudFront, thumbnails it, and
stores the blob in IndexedDB — so the cover survives restarts with no network. The
`remote` iTunes URL is the online-only backup.

---

## 2. The clients — web PWA + native SwiftUI, both client-only

**Why.** The product must feel native on Apple hardware *and* run anywhere as an
installable PWA. Two client surfaces, **same backends** — no client-specific server,
so they can't diverge on data.

| Concern | Web PWA | SwiftUI app | Shared backend |
|---|---|---|---|
| Catalog load | `seedIfEmpty()` → `current-index.json` (`src/lib/dataActions.ts`) | `CatalogService.loadIndex()` → `Config.indexURL` | `…/current-index.json` |
| Apple Music | `loadAppleMusicLibrary()` (opt-in) | `Config.appleMusicIndexURL` | `…/apple-music-index.json` |
| Persistence | IndexedDB (`src/storage`) | URLCache + edits file | — |
| Art | `/art/*` via CloudFront | `IndexAlbum.artCandidates` → `Config.artURL` | `…/art/*` |
| Audio | `useRipsStore.ts` (Ch. 5) | `RipServerService` + `PlayerEngine`/`PlayerClock` inline player (Ch. 5 §7) | rips bucket + rip server |
| Online search | `esClient.ts` + `sigv4.ts` (Ch. 6) | `SearchService` + `SigV4` | aoss `pocketdj` index |
| Streaming accounts | — | `StreamingStore` + `StreamingProvider` (Apple Music) — §5.1 | MusicKit |
| Song recognition | — | `ShazamRecognizer` "?♪?" + `ShazamCatalogMatch` — §5.2 | ShazamKit (public catalog) |

```
              ┌──────── same documents, same APIs ────────┐
              ▼                                            ▼
   ┌─────────────────────┐                     ┌─────────────────────┐
   │ Web PWA (React/Vite)│                     │ SwiftUI (apple/)    │
   │ • IndexedDB catalog │                     │ • IndexJSON decode  │
   │ • edits → meta store│                     │ • EditsStore (file) │
   │   overlay applyEdits│                     │   overlay applying()│
   │ • zustand stores    │                     │ • @Observable models│
   └─────────┬───────────┘                     └─────────┬───────────┘
             │  GET current-index.json / art / rips      │
             └──────────────────┬────────────────────────┘
                                ▼
                CloudFront (catalog/art) · rips bucket · rip server · aoss
```

**Reading the diagram.** The top bracket states the invariant: both clients hit the
*same* documents and APIs. The **web PWA** decodes the index into an internal model in
**IndexedDB**, mutates that catalog **directly** on edit (storybook §14–17), and keeps
UI state in **zustand** stores, and applies a portable **edits overlay** at read time
(`edits.ts`, byte-compatible with the native document — §3 / §3.5). The **SwiftUI** app decodes the same `IndexJSON`, keeps
a separate versioned **`EditsStore`** overlaid via `applying()` (never mutating the
index), and exposes data via **`@Observable`** models. The bottom arrow shows them
converging on the shared backends.

**Native endpoint config** (`apple/PocketDJ/Support/Config.swift`):
- dev `https://djictbz9w796r.cloudfront.net`, prod `https://d2p4cubg6se03u.cloudfront.net`
- rips `https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com`
- rip server `https://levis-imac.tail2e2bdf.ts.net` (Tailnet-only)

### 2.1 The native target — one universal SwiftUI app (XcodeGen)

**Why.** The native client must feel native on iPhone, iPad, **and** Mac without
maintaining three codebases. So `apple/` is **one universal SwiftUI app target** —
not per-platform targets — driven by **XcodeGen** so the project file is generated,
reviewable, and never hand-edited.

**Source of truth:** [`apple/project.yml`](../../apple/project.yml) (the XcodeGen spec)
+ the `apple-build` / `apple-publish` / `apple-test` skills.

```
 apple/project.yml  →  xcodegen generate  →  PocketDJ.xcodeproj (never committed-by-hand)
   ONE app target  PocketDJ  (type: application)
     supportedDestinations: [iOS, macOS]      ← multiplatform target, NOT destination:auto
     TARGETED_DEVICE_FAMILY = "1,2"            ← iPhone (1) + iPad (2)
     deploymentTarget: iOS 18.0 · macOS 15.0
     PRODUCT_BUNDLE_IDENTIFIER com.levi.pocketdj   DEVELOPMENT_TEAM EC27UF79GL (Automatic)
     SPM: ZIPFoundation
   + two test targets  PocketDJTests / PocketDJUITests  (.tests / .uitests)
```

**Reading it.** One `application` target with **`supportedDestinations: [iOS, macOS]`**
(XcodeGen's multiplatform form) times **`TARGETED_DEVICE_FAMILY "1,2"`** yields all three
runtime shapes — iPhone, iPad, Mac — from a single build; platform forks in code are
`#if os(iOS)` / `#if os(macOS)` (the toolbar transport §5.4 is the canonical example).
The Mix DSP engine (Ch. 4 §7) is **first-party AVAudioEngine**, so the target links **no
third-party audio SDK**; the only default SPM dependency is `ZIPFoundation` (the
interchange zips, §3.5). Generated artifacts (`Generated/Info.plist`, the `.xcodeproj`)
come from `project.yml`, so a file added through the Xcode UI is **dropped on the next
`xcodegen generate`** — edits go in `project.yml`. The `apple-build` skill drives the
local/simulator/Mac builds: `xcodegen generate`, then `xcodebuild -scheme PocketDJ`
against `generic/platform=iOS Simulator` (with `CODE_SIGNING_ALLOWED=NO`) or
`platform=macOS` (built unsigned, then **ad-hoc** `codesign --sign -` + de-quarantine so
the Mac `.app` opens) — automatic signing against team `EC27UF79GL` for device/archive
builds.

---

## 3. The edits database & the round-trip

**Why.** Enrichment is imperfect — a wrong genre, a mis-detected key, a stray track.
The index is read-only and machine-produced, so users must **override** locally, and
ideally fold trusted corrections back into the canonical index for everyone.

**Two mechanisms, by client:**
- **Web PWA** — edits live in a **versioned overlay too**, mirroring the native shape:
  [`src/storage/edits.ts`](../../src/storage/edits.ts) persists an `EditsDocument` in
  the IndexedDB `meta` store (key `edits`) and overlays it onto catalog items at the
  single read chokepoint (`repo.getItems` → `applyEditsToItems`, non-destructive — the
  stored index item is never mutated). Because the shape is byte-compatible with the
  native document, a native backup's `edits.json` **merges into the PWA store** on
  import (see §3.5), and a PWA backup carries `edits.json` back out — closing the
  former native→web data-loss gap. (Some in-place edit UIs may still mutate the catalog
  directly; the overlay is the portable, round-trippable mechanism.)
- **Native app** — a separate, **versioned overlay**:
  [`apple/PocketDJ/State/EditsStore.swift`](../../apple/PocketDJ/State/EditsStore.swift)
  persists an `EditsDocument`
  ([`apple/PocketDJ/Models/EditSchema.swift`](../../apple/PocketDJ/Models/EditSchema.swift))
  to `Application Support/pocketdj-edits.json`. The index is never mutated; edits apply
  at render via `IndexAlbum.applying(_:)` / `IndexSong.applying(_:)`. This document is
  the **contract for the edits round-trip**.

```
 edit on device ─▶ EditsStore.setSong/setAlbum ─▶ pocketdj-edits.json (versioned overlay)
     │                                                   render via applying()
     ▼ Settings ▸ Edits ▸ Export (sortedKeys, prettyPrinted)
 EditsDocument JSON  ──(AirDrop / Files)──▶  iMac
     │
     ▼  (DEFERRED — no tool in repo yet)
 merge tool: fold edits by id into current-index.json  ─▶ deploy.sh  ─▶ CloudFront
     ▼ next client load
 correction is canonical for ALL clients (web + native)
```

**Reading the diagram.** An edit updates the versioned overlay `pocketdj-edits.json`
(index untouched; `applying()` overlays at render). **Export** writes the deterministic
`EditsDocument` (sorted keys, pretty — so an iMac diff/merge is clean), which travels to
the iMac. The **dashed, DEFERRED** middle box is the **iMac merge tool** that would fold
each override by stable id into `current-index.json`, redeploy, and let every client
(web *and* native) inherit it — this consumer is *referenced by the schema docstrings*
but **does not yet exist** in `scripts/`.

**Edits schema rules (why it can round-trip safely):**

```
 EditsDocument { schemaVersion(=2; missing⇒v0 migrated), albums:{id:AlbumEdit},
                 songs:{id:SongEdit}, meta?:{exportedAt,appVersion,platform} }
 AlbumEdit { name?,artist?,genre?,year?,country?, audioTracks?:[AudioTrackEdit] }  ALL OPTIONAL
 SongEdit  { name?,artist?,year?,trackNumber?,bpm?,key?,camelot?,explicit?,
             sentimentKeywords? }                                   ALL OPTIONAL
 AudioTrackEdit { trackNumber?,startMs?,endMs?,bpm?,key?,camelot?,keyStrength? }   ALL OPTIONAL
```

- **Every field optional** — `nil` = "no override" → original shows → graceful degrade.
- **Versioned** — `EditsMigration.migrate` upgrades older docs; a *newer* doc decodes
  and drops unknown fields (degrades, never fails).
- **Additive-only** — never remove/repurpose a field; add an optional one + a migration.
- **Deterministic** — `.sortedKeys + .prettyPrinted` for clean iMac merges.

**How (worked example): correcting a key on iPhone.** `EditSongView` builds
`SongEdit(key:"A minor", camelot:"8A")` → `EditsStore.setSong("sng_8c1d…", edit)` →
`pocketdj-edits.json`: `{ "schemaVersion":1, "songs":{ "sng_8c1d…":{ "camelot":"8A",
"key":"A minor" } } }`. Every view renders `indexSong.applying(songEdit)`. Export →
AirDrop to iMac → (once the merge tool ships) folded by the stable id into
`current-index.json` → deploy → canonical everywhere.

---

## 3.5 The interchange format family — three zips, one envelope

**Why.** Edits aren't the only thing that must move between a phone and a Mac and a
browser. Whole **backups**, single **playlists**, and single **pockets** all need to
travel — by AirDrop, Files, or a browser download — and import on *any* client. So
PocketDJ defines **one zip envelope** with three `kind`s. Every zip carries a
`manifest.json` that self-identifies (`app:"pocketdj"`, a `kind`, a `schemaVersion`),
and the importer routes on that `kind` (falling back to entry presence). Files are
plain JSON (+ optional `art/*.webp` blobs), so the format is language-neutral: the PWA
(`fflate`) and native (`ZIPFoundation`) read each other's output unchanged.

**The pivotal split is `portable`.** A *portable* zip bundles the catalog it
references (`items.json` + `art/`), so it imports on an **empty** device. A
*non-portable* zip omits the catalog because **both clients auto-seed the same
read-only index** — collections reference songs/albums by stable id (`alb_…`/`sng_…`)
and resolve at display. The PWA's full export is portable (it has the catalog in
IndexedDB and bundles it); the **native** clients are catalog-by-reference, so every
native export is non-portable and, for backups, adds `edits.json` (the one thing the
catalog *can't* carry back).

| Zip kind | Filename suffix | Manifest (key fields) | Entries |
|---|---|---|---|
| **backup** | `.pocketdj.zip` | `{app, kind:"backup", schemaVersion:1\|2, portable, exportedAt, counts}` | `manifest.json`, `sources.json`, `pockets.json`, `playlists.json`, `setlists.json`, **+portable:** `items.json` + `art/*.webp`, **+native:** `edits.json` |
| **playlist** | `.playlist.pocketdj.zip` | `{app, kind:"playlist", schemaVersion:1, portable, exportedAt, playlistName, counts}` | `manifest.json`, `playlist.json`, `pockets.json` (DAG-expanded), **+portable:** `items.json` + `art/` + `setlists.json` |
| **pocket** | `.pocket.pocketdj.zip` | `{app, kind:"pocket", schemaVersion:1, portable:false, exportedAt, pocketName, counts:{pockets,art}}` | `manifest.json`, `pocket.json` (root), `pockets.json` (DAG-expanded children) |

```
                       manifest.json { app:"pocketdj", kind, schemaVersion, portable }
                                            │  importFile() routes on kind
              ┌─────────────────────────────┼─────────────────────────────┐
              ▼                              ▼                             ▼
       kind:"backup"                  kind:"playlist"                kind:"pocket"
   sources/pockets/playlists/      playlist.json + pockets       pocket.json + child
   setlists  (+items+art if         (+items+art+setlists          pockets (DAG-expanded)
    portable)  (+edits.json          if portable)                  — always slim
    if native)                                                     (by-reference)
              │                              │                             │
   PWA: importExportZip          PWA: importPlaylistZip        PWA: importPocketZip
   (edits.ts merge)              (fresh playlist id)           (remint pocket ids)
```

**Reading the diagram.** A single router (`src/storage/importZip.ts → importFile`)
reads the manifest `kind` and dispatches: `backup → importExportZip`,
`playlist → importPlaylistZip`, `pocket → importPocketZip`. Each importer **remints
ids** for the user-owned objects it creates (fresh playlist/pocket ids, child refs
remapped) so an import can never clobber an existing collection. The **backup**
importer additionally merges `edits.json` into the PWA edits store (imported value
wins per id) and tolerates a **native `sources.json`** (`{name,urlString,enabled}[]`,
not a PWA `DataSource[]`) by *ignoring* it rather than crashing — there's no clean
mapping from a native source-config to a PWA `DataSource` (whose items come from an
indexed catalog), so it's dropped, not adopted.

**Native vs PWA, at a glance:**
- **Native omits** `items.json` + `art/` (catalog-by-reference) and **adds** `kind` +
  (for backups) `edits.json`. `schemaVersion:2` backups, `portable:false`.
- **PWA bundles** the catalog (`portable:true` backups) and now **also** writes `kind`
  + `edits.json`, so its export is a strict superset that native reads (extra entries
  are ignored on the native side).

**The round-trip matrix** (what survives each direction). "Lossless" = every field the
*source* client holds is preserved on import; "lossy" entries note exactly what drops.

| Artifact | native → PWA | PWA → native |
|---|---|---|
| **Playlist** | **Lossless** — template + referenced pockets (DAG) import; catalog resolves by id. | **Lossless** (slim) — same. A *portable* PWA playlist's bundled `items.json`/`art` are simply ignored by native (catalog-by-reference). |
| **Pocket** | **Lossless** — root + child pockets, ids reminted, child refs remapped; members by id; **v2 free-text `notes` (each note's id + text + `position`) preserved verbatim** (intra-pocket, not catalog refs). | **Lossless** — symmetric `remintBundle` on both ends; `notes` ride along unchanged. |
| **Backup** | **Lossless for the shared subset** — pockets + playlists + setlists + **edits** all land. **Lossy only at the source:** native never *had* a bundled catalog, so there's nothing to lose there; the native `sources.json` is dropped (no PWA mapping). | **Collections + edits lossless.** **Lossy:** the PWA's bundled **catalog** (`items.json` + `art/`) and its **`DataSource[]` sources** don't transfer — native is catalog-by-reference and reads neither (by design; both re-seed the same index). |

**Still not interoperable (by design):** the **catalog itself** never crosses
client *kinds* — a PWA→native backup can't seed a native device with a PWA-only
catalog, because native has no catalog store to seed. Cross-device portability of the
*catalog* stays a PWA↔PWA concern (portable backups). Sources also don't cross: a PWA
`DataSource` and a native `SourceConfig` are different things, so each side drops the
other's `sources.json`. Everything *user-authored* — pockets, playlists, setlists, and
metadata **edits** — round-trips losslessly in both directions.

**Versioning.** Each `kind` versions independently via `manifest.schemaVersion`
(backup at 2 after pockets/playlists/setlists were added; playlist + pocket at 1).
Both readers decode **leniently** — a missing version, missing maps, or unknown future
fields degrade to "no-op" rather than throwing — so a newer client's export still
imports on an older one (it just ignores what it doesn't understand). `edits.json`
carries its *own* `schemaVersion` (the `EditsDocument`, currently 2) independent of the
zip's. The **collections** payload likewise versions independently (`collectionsSchemaVersion`,
now **2** — pockets gained the optional free-text `notes` list); additive + lenient, so a
v2 pocket's `notes` simply degrade to "ignored" on a v1 reader and members stay intact.

**How (worked example): a metadata fix made on iPhone shows up in the browser.** On
iPhone you correct a song's BPM → it lands in `pocketdj-edits.json`
(`songs:{ "sng_…":{ "bpm":128 } }`). Settings ▸ Export backup writes a `.pocketdj.zip`
(`kind:"backup"`, `portable:false`) containing your pockets/playlists/setlists +
`edits.json`. AirDrop it to the Mac, open the PWA, Settings ▸ Import data → the router
sees `kind:"backup"`, `importExportZip` imports the collections, **merges `edits.json`
into the PWA edits store**, and skips the (absent) catalog. Next time any view reads
items, `applyEditsToItems` overlays `bpm:128` onto `sng_…` — the correction is now live
in the browser, no catalog mutation, no merge tool required.

---

## 4. Deploy & invalidate (the publish loop)

```
 indexer output → public/current-index.json (+ /art via mirror-art.sh)
     ▼ scripts/deploy.sh dev|prod  (profile levi)
 build dist/ → aws s3 sync (immutable assets + no-cache shell + index)
     ▼
 aws cloudfront create-invalidation /*  (dev E123GKAO9JVETP · prod E1SP8M1SIF7Q8D)
     ▼ next boot / Settings ▸ Force refresh
 clients re-pull current-index.json (preserving pockets/playlists/setlists)
```

**Reading the diagram.** `deploy.sh` builds `dist/`, syncs it with the right cache
tiers (immutable hashed assets, no-cache shell + seed), and invalidates the env's
CloudFront distribution so the new `index.html` + hashed assets propagate together.
Clients pick it up on next boot or via Settings ▸ Force refresh, which re-pulls only
the catalog and **preserves** client-side collections.

**Checkpoint-deploy watcher (the slow-crawl case).** The Apple Music **catalog-id
resolver** (Ch. 3 §1.1) runs for ~2 days, growing `appleMusicId` coverage in
`index-out/apple-music/index.json` over time — and because `apple-music-index.json` is
now **no-cache** (§1), each redeploy actually reaches clients.
[`scripts/checkpoint-deploy-watch.sh`](../../scripts/checkpoint-deploy-watch.sh)
automates publishing that growing index *during* the crawl: a **detached** (`nohup`)
loop that, every `INTERVAL` (default 90 min), counts songs carrying an `appleMusicId`
and — once coverage has grown past `THRESHOLD` (default 10k) since the last publish —
**snapshots** the index into `public/apple-music-index.json` and runs
`deploy.sh dev` + `SKIP_BUILD=1 deploy.sh prod`, recording the deployed count in a
`.last-deploy-count` marker (idempotent across ticks; failed deploys retry next tick).
When the resolver process is gone (`pgrep`), it does a **final** snapshot+deploy of any
remaining progress and exits. It's independent of any Claude session — local AWS creds,
local index files — so the days-long crawl ships incrementally on its own.

**The catalog-id crawl completed — and the `backfill-rip` skill for the misses.** The
~2-day crawl resolved **76,134 / 92,865** songs to an `appleMusicId` (Ch. 3 §1.1) — those
**stream** via Apple Music (Ch. 5 §8). The remaining **16,730** never resolved
(`storeId === null`) — they aren't in the streaming catalog at all, so the app **falls back
to ripping** them. That miss list is written to **`apple-music-catalog-misses.csv`** at the
repo root (`songId,artist,title,album,albumId,year,trackNumber,lengthMs,fileType,source`).
The [`backfill-rip` skill](../../.claude/skills/backfill-rip/SKILL.md) turns that list into
**local rips**: it `POST`s the miss `songId`s to the rip server's batch
**`/rip-collection`** (Ch. 5 §2) — the same durable queue + single-flight dedup as the in-app
**Rip all** — so the server local-rips each from Apple Music (real-time Audio Hijack capture
→ mp3 → public S3), backfilling a streamable file for songs that can't stream. It reads the
S3 manifest up front (reporting already-ripped vs to-rip) and is **idempotent** (the server
skips songs already in the manifest), so re-running is safe; ripping is real-time at
concurrency-1, so it's a long unattended job (`scripts/rip-server.mjs` must be running).

### 4.1 Native release — TestFlight (the `apple-publish` loop)

**Why.** The PWA ships by syncing static files to S3 (§4); the native app ships through
**App Store Connect / TestFlight**. It's a **local-archive** path — no Xcode Cloud — so a
single command on the iMac builds, signs for distribution, and uploads a build that
auto-shares to the beta testers.

**Source of truth:** the `apple-publish` skill + [`apple/scripts/testflight.sh`](../../apple/scripts/testflight.sh)
(sibling of the `apple-build` skill §2.1, which makes local/simulator/Mac builds).

```
 cd apple ; ASC_KEY_ID=… ASC_ISSUER_ID=… ./scripts/testflight.sh
   xcodegen generate
   xcodebuild -scheme PocketDJ -configuration Release -destination 'generic/platform=iOS'
       -authenticationKeyPath/ID/IssuerID  -allowProvisioningUpdates   clean archive
       (BUILD_NUMBER = $(date +%s) → CURRENT_PROJECT_VERSION, so uploads never collide)
   write ExportOptions.plist { method:app-store-connect, destination:upload,
                               teamID:EC27UF79GL, signingStyle:automatic, uploadSymbols }
   xcodebuild -exportArchive  → upload to App Store Connect (App ID 6784031333,
                                "Pocket DJ - Rip, Burn, Mix")
   → "Alphas" internal group set "Automatic for Xcode Builds" → over-the-air to testers
```

**Reading it.** `testflight.sh` regenerates the project (§2.1), **archives** a **Release**
build signed for distribution via an **App Store Connect API key** (`.p8` under
`~/.appstoreconnect/private_keys/`, an **Admin**-role key — passed to the archive +
`-allowProvisioningUpdates` so signing is hands-off), stamps a **unix-timestamp build
number** so successive uploads never clash, then `-exportArchive`s with an
**`app-store-connect` / `upload`** `ExportOptions.plist` to push the build to App Store
Connect. Because **`ITSAppUsesNonExemptEncryption: false`** is baked into the Info.plist
(§5.3), the build lands **"Ready to Submit"** with no per-build export-compliance prompt, and
the **"Alphas"** internal testing group (set "Automatic for Xcode Builds") distributes every
upload **over the air**. A one-time GUI archive bootstraps the Apple Distribution cert +
grants the key headless keychain access; the App ID still needs its **MusicKit App Service**
enabled (§5.3). For tight on-device iteration *without* the Connect round-trip, the dev-device
helper `apple/scripts/deploy-iphone.sh` (§6.1) builds → installs → launches straight onto a
tethered iPhone.

---

## 5. The native app's extra sources — streaming accounts + ShazamKit

**Why.** Everything above keeps the catalog *files*-shaped: a URL you fetch
(`SourceConfig`). But the native app adds two source *kinds* that aren't files at all —
an **Apple Music subscription** the user logs into and a
**ShazamKit recognizer** that turns the song playing *in the room* back into a catalog
hit. Both are **additive and shippable-while-inert**: the app compiles and runs with
neither configured, the provider falling back to a no-op stub. (Earlier Spotify +
YouTube provider scaffolding was removed.) The full operator
checklist (portal toggles, SDKs, credentials, plist keys) lives in the cross-referenced
[`docs/streaming-integration.md`](../streaming-integration.md); this section is the
*architecture* — the seams, the registry, the gating, and how a recognized song reaches
a player.

### 5.1 Streaming providers — `StreamingProvider` / `StreamingStore`

**Source of truth:** [`apple/PocketDJ/Services/Streaming/`](../../apple/PocketDJ/Services/Streaming/)
(`StreamingProvider.swift`, `AppleMusicProvider.swift`, plus the `SongRecognizer` /
`StreamingSearch` seams),
[`apple/PocketDJ/State/StreamingStore.swift`](../../apple/PocketDJ/State/StreamingStore.swift),
[`apple/PocketDJ/Views/SettingsView+Streaming.swift`](../../apple/PocketDJ/Views/SettingsView+Streaming.swift),
and the OAuth/scene wiring in
[`apple/PocketDJ/PocketDJApp.swift`](../../apple/PocketDJ/PocketDJApp.swift).

A **`StreamingProvider`** (the protocol) is an *account link*, not a URL: `login()` /
`logout()` / `handleCallback(url:)` / `reconnectIfNeeded()` / `disconnect()` /
`play/pause/resume`, with an observable `state: StreamingConnectionState`
(`unavailable → loggedOut → authorizing → linked → connected`, or `failed`). One
concrete kind exists today (`StreamingProviderKind`: `appleMusic`; earlier `spotify` /
`youTube` were removed). **`StreamingStore`** is the registry: it builds the default set
`[AppleMusicProvider()]`, exposes `provider(_:)` / `hasAnyAvailable`, and routes any
incoming OAuth redirect + scene-phase lifecycle to whichever provider claims them. It's
injected into the SwiftUI environment in `PocketDJApp` alongside the other stores.

```
 PocketDJApp
   ├─ @State streaming = StreamingStore()  → .environment(streaming)
   ├─ .onOpenURL { streaming.handleCallback($0) }      ← a provider's OAuth redirect (if any)
   └─ .onChange(scenePhase): active → onScenePhaseActive()    (reconnectIfNeeded)
                             background → onScenePhaseBackground()  (disconnect)

 StreamingStore.providers : [any StreamingProvider]
   ┌───────────────┐
   │ AppleMusic    │
   │ #if MusicKit  │
   │  AND flag YES │
   └──────┬────────┘
          │   real impl behind #if canImport(MusicKit), no-op #else stub
          ▼
 Settings ▸ "Streaming accounts"  (SettingsView+Streaming.swift)
   one StreamingAccountRow per provider:
     state.isLinked? → "Log out"   ·  available? → "Log in"   ·  else → "Not available"
```

**Reading the diagram.** `PocketDJApp` owns the single `StreamingStore`, feeds it any
**OAuth redirect** (`.onOpenURL` → `handleCallback` hands it to the owning provider), and
ties **scene phase** to a provider's remote-connection lifecycle. The provider's *real*
implementation is compiled only behind `#if canImport(…)`, with a no-op `#else` stub — so
the default build links **no** third-party SDK and the provider reports `.unavailable`
until provisioned. Gating:

- **Apple Music** — `#if canImport(MusicKit)` **and** the build flag
  `PocketDJAppleMusicEnabled == "YES"`. `login()` shows the system `MusicAuthorization`
  consent sheet (no web redirect) and playback is in-process via
  `ApplicationMusicPlayer`. It still needs the **MusicKit App Service** enabled on the
  App ID to run on a device. Its `resolve(_:)` matcher is what actually lets an Apple
  Music (**Local**) song *stream* instead of rip — see the **stream-first, rip-last**
  provider chain in [Ch. 5 §8](./05-playback-and-rip-on-demand.md#8-stream-first-rip-last--the-native-provider-chain-playbackcoordinator)
  (it verifies the index's `appleMusicId`, Ch. 3 §1.1, then degrades to the rip server).

The **Settings UI** (`SettingsView+Streaming.streamingSection`, header literal
**"Streaming accounts"**) renders one `StreamingAccountRow` per provider — **Log in** /
**Log out** by `state`, or **"Not available"** with a developer note — sitting *beside*
the URL-catalog "Data sources." A linked streaming account is thus an additional source
kind, orthogonal to the vinyl / Apple-Music-(Local) URL catalogs (§2, Ch. 3) and to
rip-on-demand (Ch. 5).

Two further **seams** keep playback and search decoupled from the account link (each its
own protocol so a provider can offer one without the others):
`StreamingSearch` (free-text catalog search → `StreamingTrack`) and **`SongRecognizer`**
(`resolve(_ song: IndexSong) async -> StreamingTrack?`) — the single, optional coupling
point between recognition and streaming (next).

### 5.2 ShazamKit — the "?♪?" recognizer

**Source of truth:** [`apple/PocketDJ/Services/Shazam/`](../../apple/PocketDJ/Services/Shazam/)
(`ShazamRecognizer.swift` state machine, `ShazamCatalogMatch.swift` pure matcher),
[`apple/PocketDJ/Views/Shazam/`](../../apple/PocketDJ/Views/Shazam/) (`ShazamButton`,
`ShazamResultSheet`); the button sits at the **top of the Browser list**
([`BrowseView.swift`](../../apple/PocketDJ/Views/BrowseView.swift)).

```
 "?♪?" ShazamButton (top of Browser)
   tap → ShazamRecognizer.start()      (#if canImport(ShazamKit); else stub → .failed)
     │ ensureMicPermission() → .denied (mic.slash + shake → Settings) on refusal
     ▼
   SHManagedSession.results :  .listening → .recognizing → .match(SHMediaItem) | .noMatch
     │ SHMediaItem → ShazamHitInfo {title,artist,artworkURL,appleMusicID}   (ShazamKit-free)
     ▼
   ShazamCatalogMatch.resolve(info, in: app.songs)    (PURE, unit-tested)
     normalized title == AND artist-compatible
       ┌──────────────────────────────┬───────────────────────────────┐
       ▼ inCatalog(song,info)          ▼ notInCatalog(info)
   ShazamResultSheet:                 "Not in your crate" + (appleMusicID?)
   "In your crate" + Open song →       "A linked Apple Music account can play this."
   NavigationLink(value: IndexSong)    → SongRecognizer bridge (5.1)
```

**Reading the diagram.** Tapping **"?♪?"** opens an `SHManagedSession` (which owns the
mic tap + signature pipeline). The recognizer requests **mic permission itself** so a
refusal is a clean `.denied` state (the button shakes, shows `mic.slash`, and deep-links
to Settings) rather than a thrown error. A match's `SHMediaItem` is reduced to a
**ShazamKit-free** `ShazamHitInfo` so the matching logic in
**`ShazamCatalogMatch.resolve`** is **pure and unit-tested** — it normalizes title +
artist (folding diacritics, dropping "(Remastered)"-style edition tails) and resolves
against the in-memory catalog (`app.songs`). An **in-catalog** hit deep-links straight
into the existing `SongDetailView` (the destination already registered in `RootView`);
a **not-in-catalog** hit shows the recognized metadata and, when Shazam returned an
`appleMusicID`, notes that a linked Apple Music account can play it — the **one bridge**
from recognition into the streaming `SongRecognizer` seam (§5.1). With ShazamKit absent
the whole path compiles to a stub that reports *"Recognition isn't available in this
build."* — no crash.

### 5.3 Bundle id, entitlements & Info.plist

The native target's identity and capabilities changed to carry the above (all in
[`apple/project.yml`](../../apple/project.yml) +
[`apple/PocketDJ/PocketDJ.entitlements`](../../apple/PocketDJ/PocketDJ.entitlements);
re-run `xcodegen generate` after edits):

| Key | Value / file | Why |
|---|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | **`com.levi.pocketdj`** (was `net.pocketdj.app`; tests `.tests`, UI `.uitests`) | the App ID the MusicKit/ShazamKit App Services + signing are provisioned against (team `EC27UF79GL`) |
| `CODE_SIGN_ENTITLEMENTS` | `PocketDJ/PocketDJ.entitlements` (**empty** — `<dict></dict>`) | MusicKit and ShazamKit use **no** `.entitlements` key; declaring `com.apple.developer.musickit`/`shazamkit` is invalid and breaks signing. MusicKit is enabled by the **MusicKit App Service** on the App ID; ShazamKit by the framework + mic string alone |
| `INFOPLIST_KEY_NSMicrophoneUsageDescription` | "PocketDJ listens to identify the song that's playing." | mic prompt for the "?♪?" ShazamKit listen |
| `INFOPLIST_KEY_NSAppleMusicUsageDescription` | "PocketDJ uses Apple Music to play and search tracks from your subscription." | the MusicKit consent prompt |
| `PocketDJAppleMusicEnabled` (in the **base Info.plist**, not `INFOPLIST_KEY_*`) | **`YES`** | build-time gate that wakes `AppleMusicProvider` (still needs the portal MusicKit App Service to run on device). Must be a real Info.plist key — `INFOPLIST_KEY_PocketDJAppleMusicEnabled` no-ops because `INFOPLIST_KEY_*` only injects Apple's *known* keys |
| `UIBackgroundModes` | **`[audio, fetch, processing]`** (was `[audio]`) | `audio` = background playback + lock-screen Now Playing (Ch. 5 §7, §11.3); **`fetch`** lets the `BGAppRefreshTask` (rip-reconcile) run; **`processing`** lets the `BGProcessingTask` (burn-drain) run — the **background-processing** feature (Ch. 5 §11). iOS-only; macOS ignores them |
| `BGTaskSchedulerPermittedIdentifiers` | **`[com.levi.pocketdj.burn-drain, com.levi.pocketdj.rip-reconcile]`** | the two BGTask identifiers the `AppDelegate` registers + submits; iOS refuses to register an identifier not declared here (Ch. 5 §11.2) |

The `UIBackgroundModes` array can't be a scalar `INFOPLIST_KEY_*`, so `project.yml`
declares it (and `BGTaskSchedulerPermittedIdentifiers`) in its base **`info:`** block;
the same values land in [`apple/PocketDJ/Generated/Info.plist`](../../apple/PocketDJ/Generated/Info.plist).

Apple Music needs no URL scheme or third-party SDK — MusicKit uses the system consent
sheet (no web redirect) and ships with iOS. It's gated by the build flag
`PocketDJAppleMusicEnabled` + the App-ID MusicKit App Service; until provisioned the
default build ships inert. See [`docs/streaming-integration.md`](../streaming-integration.md)
for the end-to-end provisioning checklist.

### 5.4 The setlist play-mode toolbar — platform-shaped transport

**Why.** Once a set is *playing*, the detail screen stops being an editor and becomes a
**music transport**: the bar should read like one. iOS gets a centered ⏮ · ⏯ · ⏭
cluster; macOS — which has no centered nav-bar slot — keeps the flat trailing row it
always had. Both are built by one `@ToolbarContentBuilder` helper,
`setlistToolbar(_:)`, in
[`apple/PocketDJ/Views/SetlistDetailView.swift`](../../apple/PocketDJ/Views/SetlistDetailView.swift),
that branches on `#if os(iOS)` and the `isPlaying` (`setlistPlayer?.isRunning`) state.

```
 iOS — PLAYING                       iOS — IDLE  /  macOS — always
 ┌──────────────────────────────┐    ┌──────────────────────────────────────┐
 │  .principal:  ⏮  ⏯  ⏭        │    │ trailing/primaryAction (flat row):   │
 │   (transportCluster, centered)│    │  ▶Play · mode toggle · Edit · •••    │
 │                               │    │  (macOS while running adds ◀ ▶ flat) │
 │  .topBarTrailing:             │    │                                      │
 │   ⏹Stop · mode toggle · •••   │    │ •••: Add note · Rip · Burn · Rename · │
 └──────────────────────────────┘    │      Delete  (no Stop; Stop = ▶'s slot)│
   ⏹ takes ▶'s slot (NOT a menu item)└──────────────────────────────────────┘
```

**Reading the diagram.** On **iOS in play mode** the transport (`transportCluster`) is
**centered** via `ToolbarItem(placement: .principal)` — its middle button is play/**pause**
(not stop), toggling whichever backend is active (`transportIsPlaying` reads
`coordinator.isPlaying` for Apple Music streaming, else `player.isPlaying`); ⏮/⏭ step the
SET (`setlistPlayer?.skipPrevious()` / `skipNext()`, the persistent transport of §1). **Stop**
takes the **play button's own trailing slot** (`startStopButton` shows ⏹ while running) — it
is deliberately **not** a menu item. Every other action collapses into a single ••• overflow
(`overflowMenu`, `setlist-overflow`): **Add note**, then **Rip** and **Burn** as **two
separate flat items** (`CollectionRipBurnButtons` renders directly into the `Menu`, not behind
a nested submenu), **Rename**, a disabled **Edit order** (reordering mid-set would desync the
sequencer's queue index), and **Delete**. When **idle**, iOS shows the flat trailing row
(▶ Play · `PlaybackModeToggle` · `EditButton` · •••). **macOS** has no `.principal` nav bar,
so `setlistToolbar` always emits the flat `.primaryAction` layout (mode toggle · ◀/▶ while
running · ▶/⏹ · add-note · rip/burn menu · rename · delete) — same actions, no centered
cluster.

---

## 6. The rip-server launchd agent — config & external-volume access

**Why.** The rip server (Ch. 5) is the one piece of live compute the clients depend on,
so it must **auto-start at login and restart on exit** (the app never hits a stale/down
server). It runs as a **LaunchAgent** on the iMac —
[`scripts/launchd/com.pocketdj.ripserver.plist`](../../scripts/launchd/com.pocketdj.ripserver.plist)
(`com.pocketdj.ripserver`, `RunAtLoad` + `KeepAlive`, logs to
`~/.pocketdj/rip-server.log`, runs from the stable main checkout). launchd runs with a
minimal PATH, so `node`/`ffmpeg`/`aws`/`tail` dirs are set in `PATH`, and `AWS_PROFILE=levi`
is set for the S3 writes.

**`POCKETDJ_ANALOG_BASE` — where the vinyl raw files live.** The analog rip path resolves
`${POCKETDJ_ANALOG_BASE}/<album.pointer.originalFilename>` (e.g.
`SWVNewBeginningsRaw.mp3`) and **defaults to `~/Downloads`** when unset — so on the iMac,
where those raw rips live on an **external drive**, the agent's `EnvironmentVariables` set:

```
 POCKETDJ_ANALOG_BASE = /Volumes/RipBurnMix
```

If unset, **every analog rip fails** `analog file not found` (Ch. 5 §3.2). Reading
`/Volumes/*` from a launchd-spawned `node` also requires macOS **removable-volume /
Files & Folders TCC** access granted to `node` (System Settings ▸ Privacy & Security),
or the read fails even with the base set. (To require a bearer token, add `RIP_TOKEN`
to the same block and set it in Settings ▸ Rip server — tailnet-only by default; the
rips S3 bucket is public per the design.)

### 6.1 The device-deploy helper — `apple/scripts/deploy-iphone.sh`

**Why.** Iterating native features on real hardware (background playback, Now Playing,
the play-mode transport above) needs a one-shot build → install → launch onto the tethered
iPhone — without the App Store Connect round-trip of TestFlight (`apple-publish` /
[`apple/scripts/testflight.sh`](../../apple/scripts/testflight.sh)).
[`apple/scripts/deploy-iphone.sh`](../../apple/scripts/deploy-iphone.sh) does exactly that:

```
 deploy-iphone.sh   (DEV id 59C072A6-…; DEVELOPER_DIR=/Applications/Xcode.app/…)
   ▸ xcodebuild -scheme PocketDJ -destination "platform=iOS,id=$DEV"
       -configuration Debug -allowProvisioningUpdates build   (signed, → build-device/)
   ▸ xcrun devicectl device install app  --device $DEV  …/Debug-iphoneos/PocketDJ.app
   ▸ xcrun devicectl device process launch --device $DEV  com.levi.pocketdj
```

**Aqua-session codesign note.** It **must run from a GUI (Aqua) login-session shell** —
e.g. Claude Code's `!` prefix or your own Terminal — because **code-signing needs
Aqua-session keychain access** that a detached / Background-session process can't reach
(it fails `errSecInternalComponent`). The script `grep`s the build log for
`error:`/`CodeSign failed`/`BUILD SUCCEEDED|FAILED`, bails if the
`Debug-iphoneos/PocketDJ.app` product is missing, then installs + launches via
`devicectl` against the hard-coded device id. It signs with `-allowProvisioningUpdates`
against the `com.levi.pocketdj` App ID (§5.3) — the same identity TestFlight uses, so a
device build exercises the real MusicKit/ShazamKit App Services.

---

## 7. App Intents — Siri, Shortcuts & Spotlight (native)

The native app exposes its performance surface to the OS through **in-app App
Intents** (`apple/PocketDJ/Intents/`). In-app — not an extension — because every
intent drives *live, in-process* state (`SetlistPlayer`, `MixEngine`), and
`AudioPlaybackIntent` runs in the app process anyway (background-launching the app
when needed; playback then continues under the existing `audio` background mode).

**The bridge.** The app's stores are `@State` on `PocketDJApp` and travel only
through the SwiftUI environment, but intents run outside the view hierarchy — so
`PocketDJApp.init()` registers one **`IntentServices`** (`@MainActor @Observable`)
with `AppDependencyManager`, and every intent/entity query resolves it via
`@Dependency`. All intent *operations* live on `IntentServices` (thin + unit-tested;
the intent structs are adapters). To make a scene-less background launch safe, the
store **cross-wiring moved from `RootView.task` into `PocketDJApp.init()`**
(`collections.app`, `playbackMode`, `burns.lookup`, `coordinator.sourceOfSong`, …);
`RootView.task` keeps only launch *actions* (manifest refresh, reconcile, catalog
load). Intents call `ensureReady()` → the offline-first `loadIfNeeded()`.

**Entities.** `PlaylistEntity` / `PocketEntity` / `AutoMixSourceEntity` wrap the
collections by their stable prefixed-UUID ids (`pls_`/`pkt_`/`set_`). The auto-mix
source folds *pocket | setlist* into ONE speakable parameter (a Siri phrase carries
at most one), reusing `MixSource.id`'s `pocket:`/`setlist:` encoding. Queries are
`EntityStringQuery`s (case-insensitive name match) and always filter the reserved
Now Playing scratch setlist.

**The intents** (8 App Shortcuts, under Apple's 10-cap, phrases like *"Play
〈playlist〉 in PocketDJ"*):

- **Play / Shuffle Playlist · Play / Shuffle Pocket** — `collections.playNow` →
  the reserved Now Playing setlist → `setlistPlayer.play`, exactly the detail-view
  path minus navigation. Shuffle variants are separate intent types so *"Shuffle X
  in PocketDJ"* gets its own phrase.
- **Auto-Mix (pocket | setlist, shuffle)** — MixView's path: `MixResolver.loadables`
  → `AutoMixItem`s → `startAutoMix` with the Settings lead/fade, plus the same
  settings pushes the Mix tab does on open. Speakable error when the source has no
  burned songs (auto-mix is local-files-only).
- **Pause / Resume Auto-Mix** — call the **lock-screen seam** (`remotePause` /
  `remotePlay`): wall-clock-frozen suspend, resume-only-what-paused — never the
  in-app hand-mixing pause, and never `pauseBoth()` (which would END the mix).
- **Create Pocket** — the async on-device-LLM builder (Ch. 4 §4.1).
- **Open Playlist / Open Pocket** — `OpenIntent`s for Spotlight results: they park
  an `IntentRoute` on the bridge; `RootView` (owner of the `NavigationPath`)
  consumes it via `onChange` + a `.task` check for cold launches.

**Donations.** Two channels, per Apple's guidance: (1) **entities → Spotlight** —
`IndexedEntity` conformance + a debounced wipe-and-rewrite of the named index
`pocketdj-collections` after every `CollectionsStore.save()` (an `onChange` hook),
plus `updateAppShortcutParameters()` so Siri re-learns speakable names on rename;
(2) **actions → predictions** — the UI play/auto-mix call sites donate the
equivalent parameterized intent (`IntentDonations`), never from `perform()` (the
system auto-donates its own runs). Both are disabled under `PDJ_USE_FIXTURE` so
tests don't pollute the simulator.

**In-app search (system.search schema, live today).** `SearchLibraryIntent`
adopts `@AppIntent(schema: .system.search)` (18.x-era, compiles on the current
SDK): "Search PocketDJ for boogie" parks the term on
`IntentServices.pendingBrowseQuery` + a `.browseSearch` route — RootView lands on
the Browser and BrowseView consumes the term into its search field (same
atomic-take pattern as the open routes).

**The iOS/macOS 27 audio-schema layer (`AudioSchema27.swift`, compiled-out until
Xcode 27).** The "Siri AI" audio domain is implemented behind
`#if canImport(MediaIntents)` (MediaIntents is new in the 27 SDK, so with
Xcode 26.x the file compiles out and nothing changes), every type
`@available(iOS 27, macOS 27, *)`; shapes ported from Apple's CosmoTunes sample.
Inside: `AudioSongEntity` / `AudioAlbumEntity` / `AudioArtistEntity` /
`AudioPlaylistEntity` (playlists AND pockets both surface as speakable
"playlists", routed by their `pls_`/`pkt_` id prefixes) with
Entity/String/`IndexedEntityQuery` queries; the `PocketDJAudioEntity`
`@UnionValue` (song | playlist); `audio.playAudio` (natural-language play,
shuffle via `playbackAttributes`; queue insertion collapses to play-now —
PocketDJ's Now Playing replaces the queue) and `audio.addToPlaylist` (append a
song to a playlist or pocket); the MediaIntents `AudioSearch` value query
("play something upbeat" → tokenized catalog search capped at 25 songs +
name-matched collections; bare "play something" → the user's own collections);
and `AudioSchemaIndexer` — bulk Spotlight indexing of the SMALL sets (albums
~13k batched, playlists/pockets) into the separate `pocketdj-audio` named index,
chained onto CollectionsSpotlight's debounced hook via
`AudioSchemaBootstrap.install` (songs are never bulk-indexed at ~100k — they
resolve through the string/value queries). Deliberately not adopted:
`addToLibrary` + `updateAudioAffinity` (no add-to-library or like/dislike model;
audio is not an all-or-nothing domain). CAVEAT: this layer has never been
compiled against a real 27 SDK (none installed) — expect minor fix-ups on the
first Xcode 27 build, guided by the schema macros' compile-time shape errors.

---

## End of the book

Back to the [top-level overview & table of contents](../ARCHITECTURE.md).
