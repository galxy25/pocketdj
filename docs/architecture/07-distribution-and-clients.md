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
| **web** `pocketdj-{dev,prod}-web-<acct>` | `current-index.json`, `apple-music-index.json`, `digital-index.json` ("My Digital", Ch. 3), `favorites-seed.json` (§5.5), `index.html` + hashed assets + `sw.js`, `/art/*`, `/lyrics/*` | `deploy.sh`, `mirror-art.sh` (profile `levi`) | all clients (via CloudFront) |
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
- rip server + jukebox broker: **no shipped default URL** — `SettingsData.default` seeds
  both `ripServerURL` and `jukeboxServerURL` **blank**, so `hasServer` is honestly false
  out of the box and the server-dependent features show their "No rip server configured"
  state until the user sets a URL in Settings (the previous baked-in default was a
  personal-tailnet hostname inside the binary that made every server affordance render
  enabled and then fail at request time). The *operator's* deployment remains
  `https://levis-imac.tail2e2bdf.ts.net:10000` (PUBLIC via Tailscale Funnel
  since the beta-distribution promotion — tokened; rate limits exist behind
  `RIP_RATE_LIMIT=1`, default off; 443 remains the
  Tailnet-only `tailscale serve` mount. See
  [user-profiles-cloudkit-public-rip.md](../design/user-profiles-cloudkit-public-rip.md) §2)

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
     supportedDestinations: [iOS, macOS, visionOS]  ← multiplatform target, NOT destination:auto
     TARGETED_DEVICE_FAMILY = "1,2"  ·  [sdk=xros*] = "7"   ← iPhone (1) + iPad (2) + Vision Pro (7)
     deploymentTarget: iOS 18.0 · macOS 15.0 · visionOS 2.0
     PRODUCT_BUNDLE_IDENTIFIER com.levi.pocketdj   DEVELOPMENT_TEAM EC27UF79GL (Automatic)
     SPM: ZIPFoundation      embeds: PocketDJWidgets extension (§10)
   + two test targets  PocketDJTests / PocketDJUITests  (.tests / .uitests)
```

**Reading it.** One `application` target with **`supportedDestinations: [iOS, macOS,
visionOS]`** (XcodeGen's multiplatform form) times **`TARGETED_DEVICE_FAMILY "1,2"`** (plus a
per-SDK **`7`** override for the `xros*`/`xrsimulator*` slices — without it the built app is
rejected as incompatible with the visionOS platform) yields all four
runtime shapes — iPhone, iPad, Mac, Vision Pro — from a single build; platform forks in code are
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

**Multi-window (⌘N, macOS + iPadOS).** The app's scene is a value-less
**`WindowGroup(id: "main")`** — the explicit id is what lets `openWindow(id: "main")` open a
genuinely *new* window (without it, `openWindow(id:)` has nothing to match and silently
no-ops) — plus **`NewWindowCommands`** (`PocketDJApp.swift`), a `Commands` struct that
**replaces** the `.newItem` command group (so macOS gets exactly one ⌘N binding rather than
the framework's plus ours) and *adds* File ▸ New Window to iPadOS, which has no automatic
one. It's gated on `\.supportsMultipleWindows`, so iPhone registers no ⌘N at all. Every
store is `@State` on the App (created once in `init`) and injected into each window's
`RootView`, so all windows share the **same** engines/collections; only per-window UI state
(selected tab, `NavigationStack`) is independent.

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
`pocketdj-edits.json`: `{ "schemaVersion":2, "songs":{ "sng_8c1d…":{ "camelot":"8A",
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
| **playlist** | PWA `.playlist.pocketdj.zip` · native `.playlist.pdjcollection` | `{app, kind:"playlist", schemaVersion:1, portable, exportedAt, playlistName, counts}` | `manifest.json`, `playlist.json`, `pockets.json` (DAG-expanded), **+portable:** `items.json` + `art/` + `setlists.json` |
| **pocket** | PWA `.pocket.pocketdj.zip` · native `.pocket.pdjcollection` | `{app, kind:"pocket", schemaVersion:1, portable:false, exportedAt, pocketName, counts:{pockets,art}}` | `manifest.json`, `pocket.json` (root), `pockets.json` (DAG-expanded children) |

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

**The `.pdjcollection` file type (native).** The *bytes* of a native playlist/pocket
export are the same zip envelope, but the file now self-identifies as a PocketDJ document:
the custom UTI **`com.pocketdj.collection`** (`UTType.pocketDJCollection`, conforming to
`public.zip-archive` — declared via `UTExportedTypeDeclarations` + `CFBundleDocumentTypes`
in `project.yml`, §5.3), extension **`.pdjcollection`**. The extension is written
**explicitly into the export filename** (`<name>.playlist.pdjcollection` /
`<name>.pocket.pdjcollection` in `PlaylistsView`/`PocketsView`) because SwiftUI's
`fileExporter` won't append a *custom* type's extension on-device — leaving it implicit
shipped bare `.playlist` files with no type. The type fixes the cross-device import-picker
grey-out (`allowedContentTypes` can name it, and since it conforms to `.zip` a plain-zip
importer still accepts it) and makes Files / iMessage / AirDrop offer **"Open in
PocketDJ"**: `PocketDJApp`'s `.onOpenURL` routes any *file* URL through security-scoped
access into `CollectionsStore.importAny` (the same `kind`-routed importer the pickers
use), parking a cold-launch tap until onboarding completes. **Backups keep the
`.pocketdj.zip` suffix** (the exporter's `.zip` content type appends it), and the PWA
keeps its `.pocketdj.zip` suffixes throughout.

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
now **6** — pockets gained free-text `notes` (v2) then `folderId` (v4), playlists gained
`folderId` + `folders` (v3), v5 turned on lossy per-element decode + studio ids riding
`songIds`, and v6 added optional source provenance on pockets + playlists for converted-collection sync
(Ch. 3 §3.1)); additive + lenient throughout, so e.g. a v2 pocket's `notes` simply
degrade to "ignored" on a v1 reader and members stay intact.

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
auto-shares to the beta testers. Since 2026-07-16 the pipeline is **fully headless**:
credentials auto-source from `~/.config/pocketdj/asc.env`, and the archive signs with the
dedicated **`pocketdj-ci` keychain** (an "Apple Development: Created via API" identity
minted through the ASC API — helper: `apple/scripts/asc-api.mjs` — with a non-interactive
key ACL, unlocked by each script from `~/.config/pocketdj/ci-keychain-pass`), so a
detached/automated shell can ship all three platforms with zero keychain prompts.

**Source of truth:** the `apple-publish` skill + [`apple/scripts/testflight.sh`](../../apple/scripts/testflight.sh)
(sibling of the `apple-build` skill §2.1, which makes local/simulator/Mac builds).

```
 apple/scripts/testflight.sh        (also: testflight-macos.sh · testflight-visionos.sh)
   source ~/.config/pocketdj/asc.env ; security unlock-keychain pocketdj-ci
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
upload **over the air**. The local archive signs with the `pocketdj-ci` keychain's development identity and the
export **re-signs via cloud signing** (the Apple Distribution / Mac Installer certs live
Apple-side), so nothing touches the login keychain — the old one-time-GUI-archive
bootstrap is obsolete. The App ID still needs its **MusicKit App Service**
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

The link is also **two-way** for a subset of state: §5.5 mirrors the user's ♥ into (and out
of) the Apple Music account over the **Web API**, and §5.6 writes an "added to this playlist"
back to the real **library playlist**. Both are additive to everything above, and both are
inert until explicitly enabled — §5.5 by a hand-bootstrapped owner allowlist, §5.6 by the
platform simply not being macOS.

### 5.1 Streaming providers — `StreamingProvider` / `StreamingStore`

**Source of truth:** [`apple/PocketDJ/Services/Streaming/`](../../apple/PocketDJ/Services/Streaming/)
(`StreamingProvider.swift`, `AppleMusicProvider.swift`, plus the `SongRecognizer` /
`StreamingSearch` seams),
[`apple/PocketDJ/State/StreamingStore.swift`](../../apple/PocketDJ/State/StreamingStore.swift),
[`apple/PocketDJ/Views/AppleMusicSettingsView.swift`](../../apple/PocketDJ/Views/AppleMusicSettingsView.swift),
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
   ├─ .onOpenURL — non-file URLs → streaming.handleCallback($0)   ← a provider's OAuth
   │              redirect (if any); FILE URLs route to the collection-file import (§3.5)
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
 Settings ▸ "Streaming accounts"  (AppleMusicSettingsView.swift)
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

The **Settings UI** (`AppleMusicSettingsView.accountSection`, header literal
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
| `CODE_SIGN_ENTITLEMENTS` | base `PocketDJ/PocketDJ.entitlements` — the **App Group** `group.com.levi.pocketdj` (widgets, §10) + **CloudKit** `iCloud.com.levi.pocketdj` (profile/session sync). Per-SDK overrides: macOS swaps in `PocketDJ-macOS.entitlements` (**App Sandbox** + network-client/mic/user-selected-files — the Mac App Store TestFlight requirement), iOS device *and* simulator swap in `PocketDJ-CarPlay.entitlements` (§9); all three carry the same group + iCloud keys | MusicKit and ShazamKit still use **no** `.entitlements` key; declaring `com.apple.developer.musickit`/`shazamkit` is invalid and breaks signing. MusicKit is enabled by the **MusicKit App Service** on the App ID; ShazamKit by the framework + mic string alone. CloudKit is the one capability that genuinely needs entitlement keys |
| `INFOPLIST_KEY_NSMicrophoneUsageDescription` | "PocketDJ listens to identify the song that's playing." | mic prompt for the "?♪?" ShazamKit listen |
| `INFOPLIST_KEY_NSAppleMusicUsageDescription` | "PocketDJ uses Apple Music to play and search tracks from your subscription." | the MusicKit consent prompt |
| `PocketDJAppleMusicEnabled` (in the **base Info.plist**, not `INFOPLIST_KEY_*`) | **`YES`** | build-time gate that wakes `AppleMusicProvider` (still needs the portal MusicKit App Service to run on device). Must be a real Info.plist key — `INFOPLIST_KEY_PocketDJAppleMusicEnabled` no-ops because `INFOPLIST_KEY_*` only injects Apple's *known* keys |
| `UIBackgroundModes` | **`[audio, fetch, processing]`** (was `[audio]`) | `audio` = background playback + lock-screen Now Playing (Ch. 5 §7, §11.3); **`fetch`** lets the `BGAppRefreshTask` (rip-reconcile) run; **`processing`** lets the `BGProcessingTask` (burn-drain) run — the **background-processing** feature (Ch. 5 §11). iOS-only; macOS ignores them |
| `BGTaskSchedulerPermittedIdentifiers` | **`[com.levi.pocketdj.burn-drain, com.levi.pocketdj.rip-reconcile, com.levi.pocketdj.storage-prune]`** | the three BGTask identifiers the `AppDelegate` registers + submits (burn-drain reconcile, rips-manifest refresh, the storage manager's daily soft-cap prune); iOS refuses to register an identifier not declared here (Ch. 5 §11.2, §9.2) |
| `UTExportedTypeDeclarations` + `CFBundleDocumentTypes` | UTI **`com.pocketdj.collection`** (ext `.pdjcollection`, conforms to `public.zip-archive`), claimed `LSHandlerRank: Owner` | the collection-file type (§3.5): import pickers can name it, Files/iMessage offer "Open in PocketDJ". Array/nested keys, so they live in the base `info:` block |
| `LSSupportsOpeningDocumentsInPlace` | **`true`** | a document-typed app must declare how it opens files — its absence is upload warning **ITMS-90737**. `YES` is the only warning-clearing value valid on all three platforms (the macOS archiver rejects `NO`); safe because the importer takes security-scoped access and imports + discards, never editing the original |

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

### 5.5 Apple Music favorites — the Web API two-way sync, owner-gated

**Why the Web API and not MusicKit.** MusicKit has **no favorites, loves, or ratings surface
at all** — a grep of the iOS 26.5 and macOS `MusicKit.swiftinterface` files for
`favorite|love|Rating` returns only `ContentRating` (the explicit-content advisory). The love
state is reachable **only** through `api.music.apple.com`. MusicKit still carries the whole
weight of the integration, though, via **`MusicDataRequest`**: it takes an arbitrary
`URLRequest` (so PUT/POST/DELETE all work) and auto-attaches **both** the developer token and
the Music-User-Token, so there is no JWT to sign, no secret to ship, and no token to rotate on
device. `MusicDataRequest` carries **no** macOS-unavailable annotation (unlike `MusicLibrary`'s
writes, §5.6), so this path works on every platform that can import MusicKit.

**Source of truth:**
[`apple/PocketDJ/Services/Streaming/AppleMusicFavorites.swift`](../../apple/PocketDJ/Services/Streaming/AppleMusicFavorites.swift)
(request construction + the transport seam),
[`apple/PocketDJ/State/FavoritesSyncService.swift`](../../apple/PocketDJ/State/FavoritesSyncService.swift)
(push / pull / seed), and
[`apple/PocketDJ/Support/OwnerIdentity.swift`](../../apple/PocketDJ/Support/OwnerIdentity.swift)
(the gate). The local ♥ document it bridges is
[Ch. 3 §5](./03-catalog-and-data-model.md#5-favorites--the-per-profile--document).

```
 FavoritesSyncService.run()      launch (catalog .loaded) · foreground · onboarding done
   isOwner ??= OwnerIdentity.isOwner()          ← resolved ONCE per launch, cached
     │
     ├─ TRUE (owner)
     │    push()   FavoritesStore.pendingPushes  (appleMusicId != nil ∧ unpushed)
     │      favorite ⇒ BOTH halves:
     │        POST /v1/me/favorites?ids[songs]=a,b,c   ★ "Favorite Songs"
     │            batched · NO body · NO delete counterpart exists · best-effort
     │        PUT  /v1/me/ratings/songs/{id}  {"type":"rating","attributes":{"value":1}}
     │                                                             ← reversible + READABLE
     │      unfavorite ⇒ DELETE /v1/me/ratings/songs/{id}   ONLY. The ★ stays.
     │      on success: markPushed(songId, pushedAtMs: entry.atMs)
     │                  ← the SENT state's timestamp, never the wall clock
     │    pull()   GET /v1/me/ratings/songs?ids=…   (batchSize 250)
     │      lovedIds(fromRatingsPayload:) -> Set<String>?   nil ⇒ ABORT the pass
     │      → applyRemote(...) inside favorites.withCoalescedSaves { }
     │
     └─ FALSE / unresolved  (every non-owner, and every failure path)
          applySeedIfNeeded()   GET Config.favoritesSeedURL → Seed → applySeed(once)
          …and NOTHING else. No push, no pull, no export. A pure download.

 OwnerIdentity      CKContainer(id: CKCloudDocDatabase.containerID).userRecordID()
   hash = SHA256(recordName + "pocketdj-owner-v1")            (salted, domain-separated)
   isOwner = !Config.ownerICloudHashes.isEmpty ∧ hashes.contains(hash)
   FAIL CLOSED: no account · iCloud off · offline · any throw · EMPTY allowlist ⇒ false
```

**Reading the diagram.** One pass, single-flighted on `isSyncing`, runs at launch (gated on
`app.state == .loaded` *and* `onboarding.isComplete`), on foreground, and when onboarding
finishes. It resolves the gate once, then branches: the owner pushes then pulls; everyone else
gets the one-time seed and nothing more.

**The two endpoints are not the same thing, and a favorite writes both.**
`POST /v1/me/favorites` is the **★** — the Music app's "Favorite Songs". Ids ride as a
**type-scoped query parameter, `ids[songs]=`, not a bare `ids=`**: Apple documents the
parameter as "the ids of the specific type", and a bare `ids=` carries no type, so the request
is *accepted* and silently does nothing. That is the worst possible failure mode here, because
there is **no favorites GET to read back and no delete to undo a mistake** — the app would have
no way to detect that the irreversible half had been no-opping forever. The star writes are
batched and **best-effort** (`try?`): a ★ failure must not block or un-mark the rating write.
`PUT/DELETE /v1/me/ratings/songs/{id}` is the **love rating** (`value: 1`; PocketDJ never
writes `-1`), and it is the only half that is both **reversible and readable** — which is what
makes genuine two-way sync possible at all.

**The accepted consequence: un-favoriting is LOSSY.** Apple ships **no delete counterpart** to
the ★ (verified against the complete Apple Music API symbol index), so `unfavorite` does
exactly one thing — `DELETE` the rating. The track stays in Apple Music's "Favorite Songs"
until the user removes it there. This is disclosed in the UI (the Settings ▸ Debug ▸ Owner
identity footer) rather than hidden; see the storybook
[Favorites and Apple Music](../storybook/native-and-system-integration.md#favorites-and-apple-music--the-two-way-sync).

**`lovedIds` returns `Set<String>?`, and the optionality is load-bearing.** The caller
reconciles by treating every catalog id *absent* from the response as not-loved — so "no loved
ids" and "I could not read the response" are catastrophically different answers that an empty
`Set` cannot distinguish. A 200 carrying a truncated body, an HTML error page, or a schema
change would otherwise **tombstone the user's entire favorites library** in one pass. So a
top-level failure (the `data` array missing or unreadable) yields **nil** and `pull()` throws,
abandoning the pass with nothing written. Row-level tolerance is kept where it's safe: rows
decode individually through a failable box, so one malformed entry costs that one id rather
than its whole 250-song batch.

**Why the gate is an iCloud check and not an Apple Music one.** The literal requirement — "only
sync if the Apple Music profile is mine" — is **not implementable on any Apple API**:
`MusicSubscription` carries three capability booleans and no identity, the Web API has no
`/v1/me/account` (and `/v1/me/storefront` is a country code shared by millions), and the raw
Music User Token is a **rotating** bearer credential, so hashing it yields an unstable id, not
an identity. So the gate rides `CKContainer.userRecordID()` — opaque, stable per Apple ID per
container — **salted** (`"pocketdj-owner-v1"`) and SHA-256'd so the shipped constant isn't a
usable record id if the binary is inspected. It is the right substitute for a second reason:
favorites already sync through the **private** CloudKit database, so a non-owner is
*structurally* incapable of reading or writing the owner's favorites regardless of this check.
The gate's job is narrower — keep a tester's ♥ out of the **tester's own** Apple Music account,
and route them to the seed instead.

**The allowlist starts EMPTY and is bootstrapped by hand.** An empty
`Config.ownerICloudHashes` fails closed — *nobody* is the owner, **every install is
favorites-local-only** — which is how the source shipped until the constant was
bootstrapped. The hash can't be known before the app runs, so
**Settings ▸ Debug ▸ "Owner identity"** surfaces this device's hash with a Copy button; the
loop is run → copy → paste into `Config` → ship — completed 2026-07-20, so the shipped set
now carries the owner's (Levi's) hash. **Both** environments' hashes are required:
`userRecordID` is container-scoped, so the CloudKit **Development** and **Production**
containers yield different values, and a TestFlight build with only the dev hash silently
falls through to local-only. The same panel shows the resolved gate state, `lastSyncedAtMs`,
`lastError`, and — **owner-only** — an **Export favorites seed…** `fileExporter` that produces
`favorites-seed.json` (the Edits/Backup export idiom; it's hidden on a non-owner install
precisely so a tester can't publish their own taste to every other tester).

**Testability.** `AppleMusicFavoritesTransport` (`canSync` + `send(_:) -> Data`) is the network
seam, and every request builder in `AppleMusicFavorites` is a **pure** static function — so the
whole sync service, both branches of the gate (`ownerCheck` is an overridable closure), and the
seed fetcher (`fetchSeed`) drive under unit test with no account, no entitlement, and no
network. `OwnerIdentity.isOwner(hash:allowlist:)` is the pure membership test beside the
CloudKit-backed one. What is **not** headless-testable is the round-trip itself: it needs a
signed-in Apple Music account **and** a bootstrapped owner hash, so device verification is the
only proof for that leg.

### 5.6 Apple Music playlist write-back — the outbound queue

**Why.** `syncConvertedCollections` / `reconcilePlaylist` (Ch. 3 §3.1) have always been
**pull-only**: an Apple Music playlist changes upstream and the on-device duplicate follows.
Adding a song to a source playlist from inside PocketDJ only ever touched the local duplicate.
This is the missing outbound leg — every add to an Apple Music source playlist lands (a) in the
on-device duplicate immediately and (b) in the **real** library playlist as soon as MusicKit
will take it.

**Why a durable queue and not a fire-and-forget `await`.** The write fails for reasons that
have nothing to do with the user's intent — offline, MusicKit not yet authorized, the catalog
song momentarily unresolvable — and the local add has *already happened* by the time we try.
Dropping the write would leave the two sides permanently divergent with no record that anything
was owed. So the intent is persisted first and drained later, exactly like `TransferCoordinator`'s
background transfers (Ch. 5 §11).

**Source of truth:**
[`apple/PocketDJ/State/PlaylistWriteBack.swift`](../../apple/PocketDJ/State/PlaylistWriteBack.swift)
(queue + transport), `CollectionsStore.addSong(_:toIndexPlaylist:appleMusicId:)` +
`duplicateForSource(_:)`
([`CollectionsStore.swift`](../../apple/PocketDJ/State/CollectionsStore.swift)), and the
"From your sources" section of
[`AddToCollectionView.swift`](../../apple/PocketDJ/Views/AddToCollectionView.swift).

```
 Add-to sheet ▸ "From your sources" ▸ tap an Apple Music playlist
   CollectionsStore.addSong(songId, toIndexPlaylist: source, appleMusicId:)
     duplicateForSource(source)   find-or-create the ON-DEVICE duplicate
       match on (sourcePlaylistId AND sourceName); legacy nil-sourceName matches by id
     append to sequences[0]        ── and DELIBERATELY NOT to sourceSongIds
   → IndexPlaylistAdd { playlist, createdDuplicate, alreadyPresent,
                        writeBackEligible, appleMusicId? }
     eligible ⇔ appleMusicId non-empty ∧ source.sourceName == Config.appleMusicSourceName
     already in source.songIds ⇒ DON'T queue (Apple Music has it; a write would duplicate)

 Application Support/pocketdj-playlist-writeback.json   (schemaVersion 1, jobs[])
   Job { id "wbj_…", indexPlaylistId, playlistName, songId, appleMusicId,
         queuedAtMs, attempts, lastError?, state, nextAttemptAtMs?, settledAtMs? }
   JobState  queued → delivered | failed | notApplicable          queued = ONLY non-terminal
   NOT CloudKit-registered — a device-local OUTBOUND INTENT LOG (see below)

 run()   launch + foreground (runSoon), sequential, oldest-first
   no transport / !isSupported  ⇒ settleUnsupported()  → every job .notApplicable   [macOS]
   !canWrite (not authorized)   ⇒ leave QUEUED, set lastError   (the user can fix this)
   per job: transport.addSong(...) → .delivered   |   throw → attempts+1,
            backoff 30s → 1m → 2m, maxAttempts 4 → .failed
   save() after EVERY job, not once after the drain
   prune(): historyLimit 200, oldest settled first; queued + failed are NEVER pruned

 MusicKitPlaylistWriteBackTransport   #if canImport(MusicKit) && !os(macOS) && !macCatalyst
   MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(appleMusicId))
   MusicLibraryRequest<Playlist>.filter(matching: \.name, equalTo: playlistName)
   MusicLibrary.shared.add(song, to: playlist)
```

**Reading the diagram.** A tap on a source playlist row runs one composed operation: find-or-create
the duplicate, append locally, and — only when the source is Apple Music *and* the song has a
catalog id — enqueue the upstream half. The sheet then reports what actually happened in an
alert, including the three honest non-cases (already upstream, not an Apple Music track, this
device can't write). The queue is drained fire-and-forget at launch and foreground; it has no
internal timer, so those two moments are what re-arm a backed-off job.

**The invariant this must not break.** `reconcilePlaylist` computes source **removals** as
(`sourceSongIds` snapshot − current source). A locally-added song is **not** in that snapshot,
so it is never removal-eligible — and that is precisely what makes a failed write-back
harmless: the add simply stays local until a later delivery succeeds (or forever, benignly).
Writing the new song into `sourceSongIds` optimistically would make the very next catalog
refresh classify it as a source removal and **delete the user's own add**. Nothing in
`addSong(_:toIndexPlaylist:appleMusicId:)` or in this queue touches that snapshot; it advances
only when a real catalog refresh brings the song back from Apple Music itself. (`addSong` also
deliberately leaves `lastAddTarget` alone — the "Last used" shortcut re-adds to a plain local
playlist with no write-back, so remembering this target would quietly drop the Apple Music
half of a repeat add.)

**Why the document is NOT CloudKit-registered.** Unlike favorites (Ch. 3 §5) this is an
outbound *intent log*, not shared state. Syncing it would make the iPad replay a write the
iPhone already delivered — the same song added to the same Apple Music playlist twice. Related:
`save()` runs after **every** job rather than once after the drain, because `MusicLibrary.add`
is **not idempotent** and the write it performs is not retractable from this app. A background
kill mid-drain (ordinary on iOS, not exotic) would lose an in-memory-only `.delivered`, and the
next launch would re-deliver it — a duplicate track the user has to clean up by hand. One extra
small write per job is the correct trade.

**macOS settles as local-only, permanently.** `MusicLibrary`'s write methods are
`@available(…, unavailable)` on macOS and Catalyst, so the transport class is **compiled out**
there, `makeDefaultTransport()` returns nil, and `run()` marks every queued job
`.notApplicable` — terminal, with a user-facing message — rather than spinning on a retry that
can never succeed. `isSupported` is a *permanent* platform answer; `canWrite` is the *runtime*
one (Apple Music enabled + `MusicAuthorization.authorized`), and a false `canWrite` leaves jobs
**queued**, because that is a condition the user can fix. The Add-to sheet's footer reads
`canWriteBack` to say so before the tap.

**The name join, and its known limit.** The two id spaces don't meet: our `IndexPlaylist.id` is
the indexer's `Library.xml` persistent id, which MusicKit has never heard of, and
`LibraryPlaylistFilter` exposes exactly `{id, name}` — so **name** is the only handle the two
worlds share. Two library playlists with the same name are therefore indistinguishable, and the
transport takes the **first** match: failing instead would strand the job permanently on a
condition the user cannot see. The `indexPlaylistId` is still carried for de-dupe and for
naming the playlist in a stuck job. `PlaylistWriteBackTransport` is the seam that makes every
retry rule, state transition, and persistence behaviour above unit-testable against a stub —
the same idiom as `AppleMusicFavoritesTransport` (§5.5).

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
or the read fails even with the base set. (Tokens do NOT live in the plist: the server
also reads `~/.pocketdj/rip-server.env` — `RIP_TOKEN` user tier, `RIP_ADMIN_TOKEN`
admin tier, plus optional flags (`RIP_PUBLIC=0` opt-out, `RIP_RATE_LIMIT=1`) — written
by `scripts/setup-rip-funnel.sh` for the public Funnel `:10000` promotion. Public
posture is the server's default; without the env file it simply boots tokenless. The
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

## 8. Virtual-instrument packs on S3 — a new public-read artifact class

**Why.** The Performance tab's instruments (Ch. 4 §8.4) play from **SoundFont sound banks**
that are far too large to bundle in the app (a General-MIDI bank is ~32 MB) and want to be
**downloaded once and cached offline**, exactly like ripped audio. That is the same job the
**rips bucket** already does for mp3s, stems, beat grids, and waveforms (§1, Ch. 5) — a
static, public-read, globally-durable origin the client fetches with **no running server** —
so instrument packs become **a new public-read artifact class under the same `rips/` prefix**.
(The `rips/` prefix is mandatory: it's the bucket policy's public-read grant, §1.)

**Source of truth:** the S3 layout under `pocketdj-rips-011183829623/rips/instruments/`, the
client [`apple/PocketDJ/Studio/InstrumentPacks.swift`](../../apple/PocketDJ/Studio/InstrumentPacks.swift)
(manifest decode + bank download + pack store), and
[`apple/PocketDJ/Support/Config.swift`](../../apple/PocketDJ/Support/Config.swift)
(`instrumentsIndexURL`, `instrumentsBase` — added next to `ripsBase`).

```
 rips/instruments/                                (PUBLIC-READ, in the rips bucket)
   index.json   { version, attribution,
                  sharedBanks: [{ key, bytes, sha256 }],
                  packs:       [{ id, name, instrument, program, bankKey, bytes }] }
   banks/generaluser-gs-2.0.3.sf2                 32 MB GM bank (GeneralUser GS)

 v1 ships SEVEN packs (one per InstrumentKey: piano/violin/bassGuitar/acousticGuitar/
   trumpet/clarinet/harp) all referencing the ONE shared bank via bankKey → the second
   pack downloaded is INSTANT (dedupe by bankKey). Manifest supports per-pack banks later.

 CLIENT (InstrumentPacks.swift):
   index fetched like CatalogService — explicit file cache, OFFLINE-FIRST
   bank download = file-based URLSession.downloadTask (NEVER in-memory Data), progress published,
     atomic move into Application Support/studio/instruments/, existence-check idempotent
     (BurnStore stems-trio shape) → re-download is a no-op if the bank is already present
   Config.instrumentsIndexURL = ripsBase/rips/instruments/index.json ; Config.instrumentsBase = ripsBase/rips/instruments
   delete per bank in Settings ▸ Storage + the Instruments UI (Ch. 5 §9.2 — app-managed, not LRP-pruned)

 UPLOAD (dev machine only): aws --profile levi, us-west-2 — THE APP NEVER WRITES S3 (§1 private-write)
```

**Reading it.** `rips/instruments/index.json` is a small manifest listing the **shared banks**
(each with a `key`, `bytes`, and a `sha256`) and the **packs** (each an `InstrumentKey`
program mapping plus the `bankKey` it needs). v1 ships **seven packs — one per instrument** —
that all reference the **same** GeneralUser GS bank, so the client **dedupes downloads by
`bankKey`**: once any instrument's bank is on device, the other six are instant. The
manifest already carries a `sharedBanks` array and per-pack `bankKey`, so per-pack banks can
be added later with no shape change. The bank is **GeneralUser GS 2.0.3** — a license that
**permits free use and redistribution** — and the manifest's `attribution` string is shown in
the Instruments packs screen to honour it.

The client (`InstrumentPacks.swift`) treats the index like the **catalog** (§2): an **explicit
file cache, offline-first**, so the packs list opens without a network. Bank downloads use a
**file-based `URLSession.downloadTask`** (never an in-memory `Data` — a 32 MB blob has no
business on the heap), publish progress, and **atomically move** the finished file into the
app-managed `studio/instruments/` root; the download is **existence-check idempotent** (the
`BurnStore` stems-trio pattern, Ch. 5 §15), so a re-download is a clean no-op. `Config` gains
**`instrumentsIndexURL`** and **`instrumentsBase`** right beside `ripsBase`. Deletion is per
bank, from **Settings ▸ Storage** and the Instruments UI (packs are **app-managed** and, in
v1, **not** LRP-pruned — delete via the UI only, Ch. 5 §9.2). `InstrumentPacksTests` cover the
manifest decode, the GM program mapping, and the bank dedupe.

Like every other object in the rips bucket, the packs are **uploaded from the dev machine only**
(`aws --profile levi`, `us-west-2`) — **the app never writes S3** (§1's private-write half:
only the `levi` principal can `s3:PutObject`). So a pack is created and pushed exactly the way
a mirrored cover or a manifest is, and every client reads it back over public-read https with
the rip server off.

---

## 9. CarPlay — the head-unit client

**Source of truth:**
[`CarPlayScene.swift`](../../apple/PocketDJ/CarPlay/CarPlayScene.swift) (the scene delegate + template controller),
[`CarPlayModel.swift`](../../apple/PocketDJ/CarPlay/CarPlayModel.swift) (the template-agnostic browse/play/search model),
[`IntentServices.swift`](../../apple/PocketDJ/Intents/IntentServices.swift) (the shared-store bridge), and
[`PocketDJ-CarPlay.entitlements`](../../apple/PocketDJ/PocketDJ-CarPlay.entitlements).

```
 CPTemplateApplicationScene  ──didConnect──▶  CarPlaySceneDelegate
                                                    │  (a SEPARATE UIScene: no SwiftUI environment)
                                                    ▼
                                              CarPlayController(interfaceController)
                                                    │  reaches the SAME stores via ↓ (never its own)
                                                    ▼
                              IntentServices.shared ─┬─ app: AppModel
                                                     ├─ collections: CollectionsStore
                                                     ├─ setlistPlayer: SetlistPlayer   (Up Next lives here)
                                                     └─ mix / burns / studio / rips …
                                                    ▲
                              CarPlayModel(services:) ─ turns those stores into [Row] / [UpNextItem]

 CPTabBarTemplate
   ├─ "Playlists"  music.note.list      → songs (Play all / Shuffle all) → song → CPActionSheet
   ├─ "Pockets"    square.stack.fill     → songs (Play all / Shuffle all) → song → CPActionSheet
   ├─ "Albums"     opticaldisc           A–Z sectionIndexTitle → songs …
   └─ "Artists"    music.mic             A–Z → artist's albums (Play all / Shuffle all) → album → songs

 CPNowPlayingTemplate.shared  (system) ── MPNowPlayingInfoCenter set by the shared engines
   └─ Up Next button → CarPlayController.showUpNext() → CPListTemplate  (Play now / Remove / Play next / Move to end)
```

**Reading the diagram.** CarPlay is a **thin template UI over the shared engines** — the same architectural stance as every other PocketDJ client. A head unit connects a *separate* `UIScene` (`CPTemplateApplicationScene`), so `CarPlaySceneDelegate` gets **no SwiftUI environment** and therefore none of the `@State` stores that `PocketDJApp` injects into its window. Rather than construct its own `AppModel`/`CollectionsStore` — which would silently **fork a second catalog/mix graph** — the controller reaches the one live instance through `IntentServices.shared`, the process-wide handle the app registers in `PocketDJApp.init()` (the same escape hatch App Intents use from outside the view hierarchy; Ch. 7 §7). `CarPlayModel` is deliberately `import CarPlay`-free: it maps the shared stores to plain `Row`/`UpNextItem` value types (so it unit-tests on the plain host and compiles on every platform), and the iOS-only scene file is the adapter that turns those into `CPListItem`/`CPListTemplate` and fetches thumbnails. Because playback always routes through `IntentServices` → the app-scoped `SetlistPlayer`, **the head unit's Now Playing is the phone's Now Playing** — one queue, one transport, no second copy.

**Startup + the tab set.** `templateApplicationScene(_:didConnect:)` builds a `CarPlayController` and calls `start()`, which sets a "Loading…" placeholder root, then `await model.ensureReady()` (the offline-first catalog load — disk cache seeds fast) before swapping in the real root. The root is a `CPTabBarTemplate` of **three** tabs, in order: **Playlists · Pockets · For You** (confirmed at the `CPTabBarTemplate(templates:)` call). Albums and Artists were the third and fourth tabs until the owner replaced both with For You — *"in CarPlay replace artists & albums (if both exist, otherwise replace what does so we only have Playlists, Pockets & For You) with For You (new and recommended pinned up top) view"* — and the browse lists that existed only to fill them (`albums`, `artists`, `albums(byArtist:)`, `songs(byArtist:)`, `songs(inAlbum:)`, `playArtist`, `playAlbum`, plus `azListTemplate`/`indexLetter`) were **deleted, not hidden**, so nothing unreachable is left compiling. Each tab is a `CPListTemplate` given an explicit SF Symbol `tabImage` + `tabTitle` rather than a `tabSystemItem`, whose fixed system icon/label would otherwise override them. Playlists merges the user's PocketDJ playlists with the catalog's **source** playlists (Apple Music / iTunes mirrors from `app.indexPlaylists`, id-prefixed `src:` and badged with the source name).

**For You in the car.** The third tab lists **one row per tile in the phone's order** — New pinned first, In Da Zone second, then a row per collection with something worth adding. The order is *not* re-derived for the head unit: `ForYouTilesView.deriveTiles` was lifted out of the SwiftUI view into **`ForYouGrid.tiles`**, and the phone grid and `CarPlayModel.forYouTiles()` both call it, so "matching the phone" holds by construction rather than by two lists being kept in step across two files — one of which cannot be headless-tested at all. Everything decidable lives in `CarPlayForYou.swift`, a `CarPlay`-import-free extension on `CarPlayModel`, leaving the scene with template plumbing only.

**A 👍 with nowhere to add to removes itself, permanently.** A collection row's accept is also an add (`CollectionsStore.addSong`), so the next read already drops it via membership (`suggestionsExcludingMembers`) — but In Da Zone and New have no collection to receive that add, and without a filter of their own an accepted row would just sit there re-lit forever. `RecFeedbackStore.acceptedInScope(scope)` tracks exactly that — the 👍 twin of the reject tombstone (`activeTombstones`), but with no seven-day clock: there is no point at which re-offering a song the listener already endorsed becomes useful again, so it is gone from that list for good rather than sinking-and-undoable the way a 👎 does. `ForYouGrid.excludingAccepted` applies the same filter the phone tile counts by, so the car's row list and count can't drift from the phone's. It also folds into `RecFeedbackStore.zoneFeedback(scope:).suppressed` — the same set a reject tombstone feeds `ZoneEngine` — so the *next* refresh's ranking drops the accepted song from its candidate pool too, and a genuinely new suggestion fills the freed slot instead of the same song re-ranking back to the top.

The car is **read-only over the feed**: a refresh is two catalog sweeps (~96k rows for the zone, another per collection) plus a network call, so the car renders the frozen `ForYouFeedStore` snapshot verbatim and the phone owns the refresh (Ch. 6). A cache that has never been built renders `CarPlayModel.coldFeedNote` rather than a blank list. Tapping a tile drills in at depth 2 (inside CarPlay's audio-app template-stack limit) through the shared `pushRows`, which also serves collections — **▶ Play all** / **🔀 Shuffle all** on top, then the rows, then `showNowPlaying()`, which pushes `CPNowPlayingTemplate.shared` only if it isn't already the top template (no duplicate stacking). Drilling a collection (`pushSongs` → the same `pushRows`) calls the model's `playPlaylist`/`playPocket` — `try? await` into `services.play…`, i.e. the one unified sequencer.

**Two kinds of For You row, two doors.** In Da Zone and collection rows are catalog songs: `playForYouTile`/`playForYouRow` hand exactly the ids the tile's badge counted to `playSongIds`, then **stamp the recommendation scope** (`RecFeedbackStore.beginPlayback`) — *after* the play, since `playNow` → `onPlaybackReplaced` → `endPlaybackScope` would wipe a stamp made before it. That stamp is what finally gives the 👍/👎 pair on the Now Playing card something to act on: `IntentServices.currentRecTarget()` is nil unless the running queue was *begun* as a recommendation, and until this tab existed the car could not begin one, so the buttons only ever appeared for a set started on the phone. **New** rows are releases the owner does *not* own, so they cannot go through `playSongIds` at all (`CollectionsStore.playNow` drops every unresolvable id — i.e. all of them); they expand through `ReleaseStreaming` into namespaced `am:<storeID>` items exactly as the phone's New tile does, carry their own onboarding veto (that door bypasses `playSongIds`' guard, and CarPlay can cold-launch), and stamp **no** scope — a verdict on New is filed against a *release* while what plays is *tracks*. The car lists **out now only**: a pre-order has no audio, every row in a car must be playable, so its count is the out-now count rather than the phone's badge, and a release row (`isSong == false`, id `rel:<storeId>`) is offered **Play now** but not **Add to pocket / playlist**, which it has no song id for.

**KNOWN LIMITATION.** The For You tab's rows are built once, on scene connect. The rows *behind* a tile are recomputed on every tap, so drill-in content is always current — but a tile's **count** can go stale during a drive (thumb something down from the Now Playing card and the tile still shows the old number until the next connect).

**The action sheet — CarPlay has no context menu.** A song row has no swipe or long-press affordance on a head unit, so a tap opens a `CPActionSheetTemplate` (`presentSongActions`) with **Play now** / **Add to pocket / playlist** / **Cancel**. "Add to…" pushes a destination list (`pushAddTargets`) built from `model.addTargets()` — pockets then playlists, each with a `pkt:`/`pls:`-prefixed target id — and `model.addSong(_:toTargetId:)` decodes that prefix to the right `AddTarget` and writes through `CollectionsStore` (playlists append to the default chapter), returning the target name for a small confirmation toast (itself an action sheet, since CarPlay has no transient toast).

**Now Playing + editable Up Next.** The system `CPNowPlayingTemplate.shared` is what the driver sees for transport and artwork — it's populated by `MPNowPlayingInfoCenter`, set by the shared audio engines, not by CarPlay. `configureNowPlaying()` enables its **Up Next** button and registers a `CarPlayNowPlayingObserver`; the button tap routes to `showUpNext()`, which lists `services.setlistPlayer.upcoming` (keyed by `uid`, since a song can repeat in the queue — matching how `SetlistPlayer`'s live-queue edits identify rows). Because CarPlay offers no swipe-to-delete, editing an Up Next row opens another action sheet — **Play now** / **Remove from queue** / **Play next** / **Move to end** — mapping to `jump`/`removeFromQueue`/`playNext`/`moveToEnd` on the shared `SetlistPlayer` (`jump(uid:)` → `SetlistPlayer.jumpToUpcoming(uid:)`, which moves the index onto the exact tapped row and starts it through the same play-current path a skip uses), after which the queue actions call `refreshUpNext()` to rebuild the pushed list **in place** via `updateSections` — Play now instead pops back to the Now Playing card (pushing `CPNowPlayingTemplate.shared` again would put the one-instance-only template in the hierarchy twice).

**No Search tab — removed on purpose.** CarPlay previously carried a fifth Search tab (a category menu over `CPSearchTemplate`s). It's gone: head units **block the search keyboard while the vehicle is in motion**, which in practice left the template stuck on a frozen screen until the app was force-quit — a non-functional feature that could wedge the whole CarPlay session. `SearchCategory`, the search delegate, and the model's `search(_:category:)` were deleted outright (not hidden). Nothing since has reintroduced one: For You is a fixed, short list of tiles built off the frozen feed, so opening the tab makes no network call and sweeps no catalog. Finding a specific record at the wheel is served by voice — "Play X in PocketDJ" via App Intents / Siri (Ch. 7 §7), which is also the only path that works while driving anyway.

**Artwork cache.** `listItem` kicks off async cover-art loading via `loadArtwork`, which serves from an in-memory `artCache` (albumId → `UIImage`) or walks the model's `artCandidates(albumId:)` URLs, taking the first that returns a valid image and caching it, so re-browsing a list doesn't refetch.

**Entitlement + wiring.** `com.apple.developer.carplay-audio` lives in the iOS-scoped [`PocketDJ-CarPlay.entitlements`](../../apple/PocketDJ/PocketDJ-CarPlay.entitlements) — not the base `PocketDJ.entitlements`, because the base also covers visionOS, which has no CarPlay and would reject the key. `project.yml` applies it per-SDK for both device and simulator (`CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]` and `[sdk=iphonesimulator*]`), and declares an **explicit** `UIApplicationSceneManifest` that registers only the `CPTemplateApplicationSceneSessionRoleApplication` role bound to `CarPlaySceneDelegate` while `UIApplicationSupportsMultipleScenes: true` lets SwiftUI keep synthesizing the phone's own window scene (scene-manifest *generation* is turned off so the two don't collide). CarPlay UI isn't headless-testable in CI; the model is where the logic — and the tests — live (`CarPlayModelTests`, `CarPlayForYouTests`). The tab bar, the list items and the action sheets are read, not run.

---

## 10. Now Playing widgets — the WidgetKit client

**Why.** The set keeps playing while the user lives in other apps (or other rooms, on
visionOS) — the widget is the always-visible remote: cover, title/artist, ⏮⏯⏭, and an Up
Next preview, on the iPhone home screen, the macOS desktop / Notification Center, and (on
visionOS 26+) anchored in the room.

**What.** A `PocketDJWidgets` **app-extension target** (bundle
`com.levi.pocketdj.widgets`, embedded in the app by
[`project.yml`](../../apple/project.yml)) with one `StaticConfiguration` widget kind,
`PocketDJNowPlaying` ([`NowPlayingWidget.swift`](../../apple/PocketDJWidgets/NowPlayingWidget.swift)),
in small/medium/large families plus an idle "Nothing playing" placeholder. The extension
runs in its **own process** with no access to the app's live stores, so everything it
renders crosses an **App Group** (`group.com.levi.pocketdj`, in the app's *and* the
extension's per-SDK entitlements).

**How — the one-way state bridge.**
[`WidgetSync`](../../apple/PocketDJ/Playback/WidgetSync.swift) (app side, created in
`PocketDJApp` after the stores) observes the playback graph via self-re-arming
`withObservationTracking` — `SetlistPlayer` (current + queue), `PlayerEngine`,
`RipsStore.nowPlaying`, `coordinator.activeBackend`, **and
`coordinator.appleMusic.nowPlaying`/`isPlaying`** (Apple Music state lands async and can
change from outside the app) — and on every change writes a small Codable
[`NowPlayingSnapshot`](../../apple/Shared/NowPlayingSnapshot.swift) (isPlaying, title,
artist, songId, coverVersion, up-next ×6) into the shared `UserDefaults` plus the current
cover as a PNG file in the group container, then calls
`WidgetCenter.reloadAllTimelines()`. Timelines are single-entry with `policy: .never` — the
**app drives every refresh**, there is no time-based schedule. Play-state follows the engine
that OWNS the audio (`activeBackend == .appleMusic ? coordinator.isPlaying :
player.isPlaying`); the cover is re-fetched when the songId **or** the (late-arriving)
MusicKit artwork URL changes, and a refresh that would only *clear* art while the AM resolve
is still in flight is **deferred** (keep the previous art ~1 s rather than flash the
placeholder). visionOS gates the reload behind `#available(visionOS 26.0, *)` — WidgetKit
reached visionOS in 26, the extension sets `XROS_DEPLOYMENT_TARGET: "26.0"` while the app
stays 2.0.

**How — transport back.** The ⏮⏯⏭ buttons are `Button(intent:)` `AudioPlaybackIntent`s
([`WidgetTransport.swift`](../../apple/Shared/WidgetTransport.swift), compiled into BOTH
targets). While the app process is alive (the normal case — it's playing audio) the intent
runs **in the app process** and drives the wired `WidgetPlaybackController` closures
directly: toggle routes by `activeBackend` (the same one-audio-owner rule as every surface),
next/previous call the shared `SetlistPlayer`. When the app is fully quit the intent runs in
the widget process, drops the command into the App Group (`WidgetCommandChannel`, 30 s
staleness window) and posts a **Darwin notification**
(`com.levi.pocketdj.widget.command`) that the running-but-backgrounded app observes to drain
immediately; a cold app also drains on `scenePhase == .active`.

**Debuggability.** Both processes trace through `NPLog`
([`Shared/NPLog.swift`](../../apple/Shared/NPLog.swift), `subsystem com.levi.pocketdj`,
category `nowplaying`, `[app]`/`[widget]` process tags, mirrored into the in-app MixDiag
capture): every `widgetSync publish`, cover write/fetch/defer/failure, widget-process
`timeline read … coverBytes=…`, and intent routing (`in-process closure` vs `command
channel`). [`apple/scripts/np-trace.sh`](../../apple/scripts/np-trace.sh) streams the merged
two-process log — this trace is what pinned the Apple Music adoption desync (Ch. 5 §10).

When a **Settings ▸ Debug** capture is stopped, the frozen `MixDiag` buffer is archived to disk
by **`DebugSessionStore`**
([`apple/PocketDJ/State/DebugSessionStore.swift`](../../apple/PocketDJ/State/DebugSessionStore.swift)):
a metadata index at `Application Support/pocketdj-debug-sessions/index.json` (`sessions[]`, each
`{id, startedAt, endedAt, lineCount}`) plus one `<id>.txt` per session holding the full text. So
captures now **survive relaunch and accumulate** — Settings ▸ Debug lists them with per-session
**Export** / **delete** (swipe or right-click) and a **Delete-all**, rather than the previous
single in-memory buffer. A UI-test run isolates its own archive via `launchDir()` (PDJ_USE_FIXTURE).

---

## 11. Jukebox Hero — the crowd-request line

**Why.** A party wants a request line, and the crowd shouldn't have to install anything or
join the host's Wi-Fi to use it. That's the same distribution problem the whole chapter
answers — **guests are thin, public, offline-tolerant clients** — so Jukebox Hero reuses the
book's spine: **S3 is the distribution** (guests only ever GET static objects, so any number
of phones cost the host nothing), a small **iMac session broker** owns lifecycle and holds the
AWS write credentials (the app has none, §1), and **the app is the DJ** — it matches requests
and applies host decisions to the *same* `SetlistPlayer` / `MixEngine` queues everything else
plays through. No new playback or rip code; no application server the guest talks to.

**Source of truth:** [`scripts/jukebox-server.mjs`](../../scripts/jukebox-server.mjs) (the
broker, sibling of `rip-server.mjs` §6), [`scripts/jukebox-site/template.html`](../../scripts/jukebox-site/template.html)
(the guest page rendered per session), the native
[`apple/PocketDJ/Jukebox/`](../../apple/PocketDJ/Jukebox/) module (`JukeboxStore.swift` engine,
`JukeboxClient.swift` HTTP, `JukeboxMatcher.swift` + `JukeboxFoundationModel.swift` request
matching, `JukeboxModels.swift`), [`apple/PocketDJ/Views/JukeboxView.swift`](../../apple/PocketDJ/Views/JukeboxView.swift),
and the design doc [`docs/design/jukebox-hero.md`](../design/jukebox-hero.md).

### 11.1 The three roles

```
 guests' phones                    iMac (later: Lambda)              host's PocketDJ app
┌────────────────┐   requests   ┌──────────────────────┐   poll    ┌────────────────────┐
│ static site    │ ───────────▶ │   jukebox-server     │ ◀──────── │ JukeboxStore       │
│ (S3+CloudFront)│              │  (session broker)    │  decide   │  · match (FM+AM)   │
│  · now playing │              │  · sessions          │ ────────▶ │  · queue edits     │
│  · up next     │              │  · request queue     │           │  · state snapshots │
│  · request box │              │  · S3 state writer   │ ◀──────── │                    │
└────────────────┘              └──────────────────────┘   state   └────────────────────┘
        ▲                                  │ renders page,                  │
        │  poll state.json (~4s)           │ writes state.json              │ SetlistPlayer /
        └──────────── S3 web bucket ◀──────┘                                ▼ PlaybackCoordinator
                                                                    Apple Music ▸ rip server
```

**Reading the diagram.** Three parties, one shared radio station. **Guests** hold nothing but
a URL: their page GETs a static `state.json` from the web bucket every ~4 s and POSTs a
free-text request to the broker — that's the entire guest surface, so a whole venue is just
cache reads. The **jukebox-server** is *only* a session broker — it owns session lifecycle, the
durable request queue, and is the AWS-credentialed S3 writer; it does **no** ripping and **no**
matching. The **app is the DJ**: `JukeboxStore` polls the broker for new requests, matches each
against the catalog (§11.4), applies the host's decision to the live `SetlistPlayer` queue (or,
while broadcasting, the `MixEngine` auto queue, §11.6), and posts a fresh player snapshot back.
The app plays through the *existing* provider chain — Apple Music first, rip-server
stream/rip fallback (Ch. 5 §8) — so Jukebox Hero adds no playback path of its own.

### 11.2 S3 object layout + the `state.json` schema

Guest-facing objects live under a per-session prefix in the **web** bucket (§1), behind
CloudFront for the TLS a phone browser needs:

```
 jukebox/<id>/index.html   ← rendered by jukebox-server at create time (session name baked in)
 jukebox/<id>/state.json   ← no-cache; rewritten by the broker on every host snapshot
```

The QR / share URL is `https://<cloudfront-domain>/jukebox/<id>/` (dev
`djictbz9w796r…`, prod `d2p4cubg6se03u…`). Because these objects are **written by the broker at
runtime, not by `deploy.sh`**, the deploy sync must not treat them as stale build output —
`scripts/deploy.sh` gains **`--exclude "jukebox/*"`** on its `--delete` sync (alongside the
existing `art/*` / `lyrics/*` excludes, §1) so a routine PWA deploy never prunes a live
jukebox out from under its guests.

`state.json` is the single document every guest polls. The broker composes it by merging the
host's latest player snapshot with the server-side request statuses, then writes it **no-cache**:

```json
{
  "v": 1, "jukeboxId": "jb7k3q9d", "name": "Levi's Garage Party",
  "updatedAt": 1789600000000, "ended": false, "expiresAt": 1789686400000, "hear": false,
  "nowPlaying": { "title": "…", "artist": "…", "lengthMs": 214000, "positionMs": 63000,
                  "streamUrl": "https://pocketdj-rips-….s3….amazonaws.com/rips/<id>.mp3" },
  "upNext":   [ { "title": "…", "artist": "…" } ],
  "played":   [ { "title": "…", "artist": "…", "endedAt": 1789599786000 } ],
  "requests": [ { "id": "rq_…", "title": "…", "artist": "…",
                  "status": "pending|queued|denied|played" } ]
}
```

`positionMs` is snapshot-time only; the guest page animates its progress bar locally between
4-second polls. **`hear` is the view-only-vs-View+Hear gate** (§11.3): while `false` no audio
URL is published; while `true` the broker carries the current track's **public rips-bucket mp3**
as `nowPlaying.streamUrl`, and the page's user-gesture-gated **📻 Tune in** button turns it
into a synced radio client (§11.3).

**`played` is the session's history, derived by the broker** (`notePlayed` in
`jukebox-server.mjs`, server `version: 2`): a state POST that replaces one sanitized track
with a *different* one — or with nothing — appends the outgoing track to the session's played
log. Same title+artist is a position tick, not a transition, **except** a hard rewind
(>30 s → <10 s), which is a back-to-back replay and logs the first spin (Mix broadcasts post
no position, so they can never trip that rule). Deriving on the broker instead of trusting a
client-sent list covers every host source — setlist deck, Auto-DJ mix, single rip plays —
with zero wire-protocol change, and records what guests actually saw as Now Playing. The full
log (last **100**) persists in `session.json` and survives restarts; `state.json` publishes
the newest **30**. The guest page renders it as a **Previously Played** card behind a reveal
button — newest first, with local end times.

### 11.3 View-only vs View + Hear — only public rips ever leave the host

A session is **view-only by default**: a crowd-sourced request line where guests see the music
and ask for songs but don't hear it. The DJ can flip **View + Hear** on the live session
(a toggle in the tab); the host's snapshots then set `hear:true` and attach
`nowPlaying.streamUrl` — it rides the state POST (§11.5), not the lifecycle `config` route. The invariant that keeps this safe: **only rips-bucket audio is ever
distributed.** A DRM'd Apple Music stream never leaves the host, so a track playing from Apple
Music stays view-only *even in hear mode* — until its stream-through-rip (Ch. 5 §8) lands in the
manifest, at which point a later snapshot picks the public URL up automatically. This is the
same public-rips-only rule the offline stem/burn surfaces obey (Ch. 5 §15).

With hear on, the guest page behaves as a full **internet-radio client** (no app): the
`<audio>` element streams the mp3 **directly from the public rips bucket** (the broker never
proxies audio bytes), drift-syncs to `positionMs + (now − updatedAt)` re-seeking only on >3 s
drift, and auto-advances on track change by swapping `src` (later plays ride the original tap
gesture). The page's playback state machine handles the edges deliberately: it never seeks
past the file's end and never calls `play()` on an **ended** element (the HTML spec rewinds
an ended element to 0 — the stale window between a track's natural end and the next
state.json used to replay the intro); an element **`pause` the page didn't initiate**
(headphone unplug, an interruption, lock-screen pause on browsers without Media Session
routing) tunes the radio *off* rather than being fought — page-initiated pauses ride a
`pagePause` flag, natural-end and error-induced pauses are excluded; a fatal media `error`
reloads the source on a 2 s cadence (`play()` cannot revive an errored element) with a
persistent "stream hiccup" hint; and the **Media Session API** puts the station on the lock
screen (track/artist/jukebox name, `playbackState` "playing" only while a stream is actually
live) with play/pause action handlers gated on the session not having ended. `showEnded()`
takes the radio off the air: audio stopped, Media Session card cleared.

### 11.4 Matching — on-device, catalog-first

`JukeboxStore` runs each free-text request through `JukeboxMatcher` before it reaches the
inbox, reusing the recognizer's normalizer and the browser's search keys:

1. `ShazamCatalogMatch.norm`-exact match against the catalog (§5.2);
2. folded-`contains` over `AppModel.searchKeys` → scored top-N candidates;
3. an **on-device Foundation Models** pick over that candidate list
   (`JukeboxFoundationModel`, a `@Generable` choice behind a protocol seam + availability
   gate, the `FoundationModelPocketBrief` pattern of Ch. 4 §4.1 — graceful fallback to the top
   fuzzy candidate when FM is unavailable);
4. no catalog hit → `AppleMusicProvider.search` (§5.1) → an Apple-Music-only match
   (`am:<storeID>`), playable via the existing coordinator chain + stream-through-rip.

A host **decision** then edits the live queue directly: **Play Next** → `insertNextInQueue`,
**Play Last** → `appendToQueue`, **Surprise Slot** → the new `insertRandomInQueue` (a uniform
slot in the upcoming tail) — all on the app-scoped `SetlistPlayer` (Ch. 5) — after which the
app POSTs the decision so the guest's request status flips.

### 11.5 The broker — endpoints, auth, rate limits

`jukebox-server.mjs` is a dependency-free `node:http` service on port **8788**, a structural
sibling of the rip server (§6): launchd `KeepAlive`
([`com.pocketdj.jukeboxserver.plist`](../../scripts/launchd/com.pocketdj.jukeboxserver.plist)),
logs to `~/.pocketdj/jukebox-server.log`, S3 writes via the `aws` CLI (profile `levi`)
serialized per jukebox. Durable session state lives under `~/.pocketdj/jukebox/<id>/`
(`session.json`, `requests/<reqId>.json`) and **reloads on boot**, so a restart never drops a
live party.

| Route | Who | Body → Result |
|---|---|---|
| `GET /health` | anyone | `{ ok, service:"jukebox", version }` |
| `POST /jukebox` | host (**server token**) | `{ name, timeless }` → `{ jukeboxId, hostKey, url, timeless, expiresAt }`; renders + uploads the page, seeds `state.json` |
| `POST /jukebox/:id/config` | host (**hostKey**) | `{ timeless }` → `{ timeless, expiresAt }` — flips lifecycle mode |
| `POST /jukebox/:id/end` | host (**hostKey**) | marks ended, publishes final `ended:true` state |
| `POST /jukebox/:id/state` | host (**hostKey**) | `{ nowPlaying, upNext }` → merged with request statuses, written to S3 (debounced ≥1 s) |
| `POST /jukebox/:id/request` | **guest (public)** | `{ title, artist, clientId }` → `{ requestId }`; rate-limited, lengths capped (120 chars) |
| `GET /jukebox/:id/requests?since=<seq>` | host (**hostKey**) | `{ requests, seq }` — pending + recently-decided |
| `POST /jukebox/:id/requests/:reqId/decision` | host (**hostKey**) | `{ action:"denied"\|"next"\|"end"\|"random", matchedTitle?, matchedArtist? }` |

**Two-tier auth.** *Creating* a jukebox needs the process-wide **`JUKEBOX_TOKEN`** bearer (empty
= open, local-dev only) — the gate on who may spin up sessions on this broker at all. Every
*per-session* host action then authenticates with the **`hostKey`** minted at create time (a
128-bit secret, accepted as a bearer or `?hostKey=`), so possessing the token to make one
jukebox never grants control of another's. Guest endpoints (`/request`) take **no** auth — they
must be reachable by strangers — and are instead **rate-limited two ways**: a **per-client 15 s
gap** (`minGapMs`, keyed on `clientId`) throttles a single phone, and a **per-IP sliding
window** of **12 requests / 60 s** (`ipWindowMax`/`ipWindowMs`) caps abuse *without* throttling
the whole room — a venue's crowd typically NATs to one public IP, so a per-IP *gap* would
punish everyone; the window lets a busy party request freely while still bounding a flood. A
client also can't stack more than a handful of **pending** requests at once.

### 11.6 Broadcast — the Mix tie-in

The full feature is a physical party: the DJ on the **Mix** tab (Ch. 4 §7), the crowd on the QR
code, **the setlist the shared concept.** The Mix toolbar gains a **Broadcast** button (antenna,
next to Record, [`MixView.swift`](../../apple/PocketDJ/Mix/MixView.swift)): one tap creates a
session if none is live and pushes the Jukebox view onto the Mix stack. The state snapshot is
composed **by who OWNS the audio** — a running/auto Mix first (the on-air deck's track + the
auto queue's tail as "up next"), then the app-scoped `SetlistPlayer`, then a standalone single
play — the same one-audio-owner rule the widgets and lock-screen card follow (§10, Ch. 5).

While auto-mixing, an accepted request is inserted into the auto queue via
**`MixEngine.autoQueueInsert`** — never before `autoNextToLoad`, so a track already
loaded/preloaded on a deck is never displaced. **In-mix actions always win:** manual deck loads,
skips, and pauses behave exactly as they do without a broadcast; the jukebox only fills slots the
DJ hasn't committed to. One constraint bridges to the burn store: a Mix deck can only load a
**burned** file, so accepting an unburned request during a broadcast kicks the existing
rip+burn pipeline (`BurnStore.startRipAndBurn`, Apple-Music-only matches under their `amrec_`
id) and parks a pending insert that lands the moment the file exists (15 min cap). Hear mode
during a broadcast streams the **unmixed** track from S3 (public rips only, §11.3); streaming
the actual mix output — a **live radio mode** — is the planned follow-up, not v1.

### 11.7 Public exposure — Tailscale Funnel, not the Tailnet

The rip server (§6) was **Tailnet-only** until the beta-distribution promotion (2026-07,
[user-profiles-cloudkit-public-rip.md](../design/user-profiles-cloudkit-public-rip.md)) —
it now ALSO rides Funnel on `:10000` with tiered tokens (+ per-IP rate limits behind
the `RIP_RATE_LIMIT=1` flag, default off)
([`scripts/setup-rip-funnel.sh`](../../scripts/setup-rip-funnel.sh)); 443 keeps the
Tailnet-only `serve` mount. Jukebox Hero was public first: **guests are strangers on the
open internet**, so the broker must be *publicly* reachable. The interim answer (before
the Lambda migration) is a **Tailscale Funnel** path-mount on the iMac
([`scripts/setup-jukebox-funnel.sh`](../../scripts/setup-jukebox-funnel.sh)):

```
 tailscale funnel --bg --set-path /jukebox http://127.0.0.1:8788
   → public base  https://levis-imac.tail2e2bdf.ts.net/jukebox
```

**Reading it.** Funnel exposes *only* the `/jukebox` path of the local `:8788` service to the
public internet over TLS — the rest of the machine (and the Tailnet-only rip server on its own
host name) stays private. The rendered guest page bakes this base in (`JUKEBOX_PUBLIC_BASE`) for
its POSTs, and the app targets whatever base is set in **Settings ▸ Jukebox Hero**
(`SettingsData.jukeboxServerURL` — seeded **blank** like the rip-server URL, §2: no shipped
default, so the Jukebox tab honestly reports no server until one is configured). Because
that base is the *one* externally-visible coupling, the Lambda migration below is a single
URL swap.

### 11.8 Deferred — the Lambda migration

The broker's handlers are written as **pure `(ctx, params, body) → {status, json}` functions
over a small storage interface** (filesystem today), precisely so the same module drops into a
Lambda handler behind an **HTTP API Gateway** later — mirroring the search-proxy pattern
(`scripts/lambda/deploy-search-proxy.sh`; this account blocks public Lambda **Function URLs**, so
HTTP API + a CloudFront `/jukebox-api/*` behavior is the path, as with the search proxy). A
future `scripts/lambda/deploy-jukebox.sh` would pair that handler with a **DynamoDB/S3 storage
adapter** and move the public base off Funnel — the interim `jukebox-server.mjs` process on the
iMac is v1. This is tracked in the [Apple doc's Status ▸ Ch. 7](../ARCHITECTURE-APPLE.md#ch-7--distribution-clients--edits) deferred list.

---

## End of the book

Back to the [architecture index](../ARCHITECTURE.md), the
[Apple + shared-core overview](../ARCHITECTURE-APPLE.md), or the
[Android port plan](../ARCHITECTURE-ANDROID.md).
