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
| Audio | `useRipsStore.ts` (Ch. 5) | `RipServerService` | rips bucket + rip server |
| Online search | `esClient.ts` + `sigv4.ts` (Ch. 6) | `SearchService` + `SigV4` | aoss `pocketdj` index |

```
              ┌──────── same documents, same APIs ────────┐
              ▼                                            ▼
   ┌─────────────────────┐                     ┌─────────────────────┐
   │ Web PWA (React/Vite)│                     │ SwiftUI (apple/)    │
   │ • IndexedDB catalog │                     │ • IndexJSON decode  │
   │ • edits → IndexedDB │                     │ • EditsStore (file) │
   │   (direct mutate)   │                     │   overlay applying()│
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
UI state in **zustand** stores. The **SwiftUI** app decodes the same `IndexJSON`, keeps
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
- **Web PWA** — edits **mutate the IndexedDB catalog directly** (no portable edits
  document; **no round-trip back to the iMac today** — web edits are local).
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
 EditsDocument { schemaVersion(=1; missing⇒v0 migrated), albums:{id:AlbumEdit},
                 songs:{id:SongEdit}, meta?:{exportedAt,appVersion,platform} }
 AlbumEdit { name?,artist?,genre?,year?,country? }                  ALL OPTIONAL
 SongEdit  { name?,artist?,year?,trackNumber?,bpm?,key?,camelot?,explicit?,
             sentimentKeywords? }                                   ALL OPTIONAL
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

## End of the book

Back to the [top-level overview & table of contents](../ARCHITECTURE.md).
