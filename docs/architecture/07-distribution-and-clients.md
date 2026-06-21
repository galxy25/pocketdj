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
  `current-index.json` → `no-cache` (auto-updating SW + seed always revalidate).
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
| Streaming accounts | — | `StreamingStore` + `StreamingProvider` (Apple Music / Spotify / YouTube) — §5.1 | provider OAuth / SDKs |
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

---

## 5. The native app's extra sources — streaming accounts + ShazamKit

**Why.** Everything above keeps the catalog *files*-shaped: a URL you fetch
(`SourceConfig`). But the native app adds two source *kinds* that aren't files at all —
a **streaming subscription** the user logs into (Apple Music · Spotify · YouTube) and a
**ShazamKit recognizer** that turns the song playing *in the room* back into a catalog
hit. Both are **additive and shippable-while-inert**: the app compiles and runs with
none configured, every provider falling back to a no-op stub. The full operator
checklist (portal toggles, SDKs, credentials, plist keys) lives in the cross-referenced
[`docs/streaming-integration.md`](../streaming-integration.md); this section is the
*architecture* — the seams, the registry, the gating, and how a recognized song reaches
a player.

### 5.1 Streaming providers — `StreamingProvider` / `StreamingStore`

**Source of truth:** [`apple/PocketDJ/Services/Streaming/`](../../apple/PocketDJ/Services/Streaming/)
(`StreamingProvider.swift`, `AppleMusicProvider.swift`, `SpotifyProvider.swift`,
`YouTubeProvider.swift`, plus the `SongRecognizer` / `StreamingSearch` seams),
[`apple/PocketDJ/State/StreamingStore.swift`](../../apple/PocketDJ/State/StreamingStore.swift),
[`apple/PocketDJ/Views/SettingsView+Streaming.swift`](../../apple/PocketDJ/Views/SettingsView+Streaming.swift),
and the OAuth/scene wiring in
[`apple/PocketDJ/PocketDJApp.swift`](../../apple/PocketDJ/PocketDJApp.swift).

A **`StreamingProvider`** (the protocol) is an *account link*, not a URL: `login()` /
`logout()` / `handleCallback(url:)` / `reconnectIfNeeded()` / `disconnect()` /
`play/pause/resume`, with an observable `state: StreamingConnectionState`
(`unavailable → loggedOut → authorizing → linked → connected`, or `failed`). Three
concrete kinds exist (`StreamingProviderKind`: `appleMusic`, `spotify`, `youTube`).
**`StreamingStore`** is the registry: it builds the default set
`[AppleMusicProvider(), SpotifyProvider(), YouTubeProvider()]`, exposes
`provider(_:)` / `hasAnyAvailable`, and routes incoming OAuth redirects + scene-phase
lifecycle to whichever provider claims them. It's injected into the SwiftUI environment
in `PocketDJApp` alongside the other stores.

```
 PocketDJApp
   ├─ @State streaming = StreamingStore()  → .environment(streaming)
   ├─ .onOpenURL { streaming.handleCallback($0) }      ← pocketdj://spotify-login-callback
   └─ .onChange(scenePhase): active → onScenePhaseActive()    (reconnectIfNeeded — Spotify App Remote)
                             background → onScenePhaseBackground()  (disconnect)

 StreamingStore.providers : [any StreamingProvider]
   ┌───────────────┬──────────────────┬───────────────────┐
   │ AppleMusic    │ Spotify          │ YouTube           │
   │ #if MusicKit  │ #if SpotifyiOS   │ search: Data API  │
   │  AND flag YES │  + creds present │ play: #if YouTube-│
   │               │  + Premium       │   iOSPlayerHelper │
   └──────┬────────┴────────┬─────────┴─────────┬─────────┘
          │   each real impl behind #if canImport(...), no-op #else stub
          ▼
 Settings ▸ "Streaming accounts"  (SettingsView+Streaming.swift)
   one StreamingAccountRow per provider:
     state.isLinked? → "Log out"   ·  available? → "Log in"   ·  else → "Not available"
```

**Reading the diagram.** `PocketDJApp` owns the single `StreamingStore`, feeds it the
**OAuth redirect** (`.onOpenURL` — e.g. `pocketdj://spotify-login-callback` comes back
here and `handleCallback` hands it to the owning provider), and ties **scene phase** to
App-Remote lifecycle (Spotify must drop its connection when backgrounded, reconnect on
active). Each provider's *real* implementation is compiled only behind `#if
canImport(…)` of its SDK, with a no-op `#else` stub — so the default build links **no**
third-party SDK and every provider reports `.unavailable`. Gating per provider:

- **Apple Music** — `#if canImport(MusicKit)` **and** the build flag
  `PocketDJAppleMusicEnabled == "YES"`. *This branch flips that flag ON*, so Apple Music
  is the one provider wired live; `login()` shows the system `MusicAuthorization`
  consent sheet (no web redirect) and playback is in-process via
  `ApplicationMusicPlayer`. It still needs the **MusicKit App Service** enabled on the
  App ID to run on a device.
- **Spotify** — `#if canImport(SpotifyiOS)` + non-empty `SpotifyClientID` /
  `SpotifyRedirectURL`; needs the SDK linked, a dashboard client, and a **Premium**
  account. **Scaffolded — pending the SDK + credentials.**
- **YouTube** — search gated on a Data-API key, playback on
  `#if canImport(YouTubeiOSPlayerHelper)` (embedded `YTPlayerView`, never an extracted
  stream). **Scaffolded — pending the key/helper.**

The **Settings UI** (`SettingsView+Streaming.streamingSection`, header literal
**"Streaming accounts"**) renders one `StreamingAccountRow` per provider — **Log in** /
**Log out** by `state`, or **"Not available"** with a developer note — sitting *beside*
the URL-catalog "Data sources." A linked streaming account is thus a fourth source kind,
orthogonal to the vinyl / Apple-Music-(Local) URL catalogs (§2, Ch. 3) and to
rip-on-demand (Ch. 5).

Two further **seams** keep playback and search decoupled from the account link (each its
own protocol so a provider can offer one without the others):
`StreamingSearch` (free-text catalog search → `StreamingTrack`; YouTube via the Data
API) and **`SongRecognizer`** (`resolve(_ song: IndexSong) async -> StreamingTrack?`) —
the single, optional coupling point between recognition and streaming (next).

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
| `CODE_SIGN_ENTITLEMENTS` | `PocketDJ/PocketDJ.entitlements` | one file carrying `com.apple.developer.musickit` + `com.apple.developer.shazamkit`; enforced only when signing for a device/distribution |
| `INFOPLIST_KEY_NSMicrophoneUsageDescription` | "PocketDJ listens to identify the song that's playing." | mic prompt for the "?♪?" ShazamKit listen |
| `INFOPLIST_KEY_NSAppleMusicUsageDescription` | "PocketDJ uses Apple Music to play and search tracks from your subscription." | the MusicKit consent prompt |
| `INFOPLIST_KEY_PocketDJAppleMusicEnabled` | **`"YES"`** (flipped on this branch) | build-time gate that wakes `AppleMusicProvider` (still needs the portal App Service to run on device) |
| `UIBackgroundModes` | `[audio]` | background playback + lock-screen Now Playing for the inline player (Ch. 5 §7) |

The **Spotify / YouTube OAuth redirect schemes** are *arrays* (`CFBundleURLTypes`,
`LSApplicationQueriesSchemes`) and so can't be injected as scalar `INFOPLIST_KEY_*`
values — `project.yml` keeps a **commented `info:` block** showing exactly what to paste
(plus commented `SpotifyiOS` / `YouTubeiOSPlayerHelper` SPM packages) when a developer
provisions those providers. Until then the default build links neither SDK and ships
inert. See [`docs/streaming-integration.md`](../streaming-integration.md) for the
end-to-end provisioning checklist.

---

## End of the book

Back to the [top-level overview & table of contents](../ARCHITECTURE.md).
