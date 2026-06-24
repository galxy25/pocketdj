# PocketDJ — Stream-Through-Rip + Collection Rip/Burn — Design Doc

## Overview

This adds two native-app (`apple/`) features plus a minimal set of `scripts/rip-server.mjs` additions. Everything is net-new *wiring* on infrastructure that already exists and is verified in the current code:

- The idempotent, durable, single-flight `POST /rip` with an on-disk per-`songId` queue (`scripts/rip-server.mjs:397–412`, queue at `:129–171`).
- `RipsStore.ensureURL` / `downloadData` + the public-S3 manifest client (`apple/PocketDJ/State/RipsStore.swift`).

There is **no** collection-level Rip/Burn in `apple/` today (confirmed — only the PWA setlist + `.claude/skills/burn-setlist/burn-setlist.mjs` have anything similar, which is out of scope). The memory note that "setlist Rip-all/Burn may exist" in the native app is stale.

The two features:

- **Feature 1 — Stream-through-rip:** when Apple Music streaming wins a play, fire one fire-and-forget `POST /rip` so the track is silently captured to S3 for later. Playback is never blocked.
- **Feature 2 — Rip (collection) + Burn (collection):**
  - **Rip** = server-side batch enqueue (`POST /rip-collection`) reusing the existing durable queue → S3 upload + manifest. No local download.
  - **Burn** = app-side serial download of *already-ripped* songs to local storage + a human-readable sidecar, with a machine-readable index designed so a future offline player / live-mixer can enumerate tracks. Burn never blocks on a live rip.

**Explicitly deferred:** offline playback and live mixing. This doc only builds the *data model and storage layout* those will consume; neither engine is implemented.

---

## New rip-server API

### `POST /rip` — unchanged contract (internal refactor only)

The accept body is factored into a helper, but the HTTP response shape is **byte-identical** to today so the `RipsStore.Job` decoder (`RipsStore.swift:34–59`) is untouched.

New helper in `scripts/rip-server.mjs`:

```js
function acceptRip(songId) {
  const song = songById.get(songId);
  if (!song) return { job: null, status: 'unknown' };
  if (manifest[songId]) return { job: null, status: 'ready', url: publicUrl(manifest[songId].key) };
  const resourceKey = song.sourceType === 'analog' ? song.albumId : songId;
  const existingId = inflight.get(resourceKey);
  if (existingId && jobs.has(existingId)) return { job: jobs.get(existingId), status: 'inflight' };
  const job = { jobId: randomUUID(), songId, resourceKey, phase: 'queued', createdAt: Date.now() };
  jobs.set(job.jobId, job);
  inflight.set(resourceKey, job.jobId);
  persistQueue(job);
  setPhase(job, 'queued');
  enqueue(job);
  return { job, status: 'queued' };
}
```

`POST /rip`'s handler is rewritten to call `acceptRip` and then respond *exactly as before*:

- `status === 'unknown'` → `404 { error: 'unknown songId' }`
- `status === 'ready'` → `200 { jobId: null, songId, phase: 'ready', url }`
- otherwise → `200 jobView(job)`

**Idempotency:** unchanged — manifest skip + single-flight `inflight` join by `resourceKey` + durable per-`songId` queue file + `resumePending` crash recovery.

### `POST /rip-collection` — NEW (Feature 2 Rip)

Batch-enqueue every song in a collection, reusing the existing queue / dedup / concurrency-1 worker / S3 upload verbatim.

**Auth:** identical to `POST /rip` — it sits below the single shared `authed()` Bearer gate (`scripts/rip-server.mjs:403`), which is **permissive (public) when no `RIP_TOKEN` is configured**. During development the rip server runs **tokenless / public**, so `/rip-collection` is reachable with no header — exactly like `/rip`. There is **no** `/rip-collection`-specific fail-closed branch.

**Request:**
```json
{ "songIds": ["id1", "id2", "..."] }
```
- Empty array allowed (returns empty result).
- `songIds` is deduped server-side.
- **No length limit** — it is async and the durable queue scales out as needed.

**Response (200):**
```json
{
  "results": [
    { "songId": "id1", "status": "ready",    "jobId": null,        "url": "https://…/rips/…mp3" },
    { "songId": "id2", "status": "queued",    "jobId": "uuid",      "url": null },
    { "songId": "id3", "status": "inflight",  "jobId": "uuid",      "url": null },
    { "songId": "x",   "status": "unknown",   "jobId": null,        "url": null }
  ],
  "counts": { "ready": 1, "queued": 1, "inflight": 1, "unknown": 1, "total": 4 }
}
```

**Error responses:**
- `401` only when a `RIP_TOKEN` *is* configured and the request lacks/uses a wrong Bearer token — emitted by the shared `authed()` gate, identical to `/rip`. With no token configured there is no auth error.
- No `413` / id cap.

**Handler** (inside `createServer`, below the shared auth gate `:403`, before the final 404):

```js
if (path === '/rip-collection' && req.method === 'POST') {
  // No length limit: it is async and the durable queue scales out as needed.
  const { songIds } = await readJson(req);
  const ids = Array.isArray(songIds) ? [...new Set(songIds)] : [];
  const results = ids.map((id) => {
    const r = acceptRip(id);
    return { songId: id, status: r.status, jobId: r.job ? r.job.jobId : null, url: r.url || (r.job && r.job.url) || null };
  });
  const counts = results.reduce((c, r) => { c[r.status] = (c[r.status] || 0) + 1; c.total++; return c; },
                                { ready: 0, queued: 0, inflight: 0, unknown: 0, total: 0 });
  return send(res, 200, { results, counts });
}
```

**Idempotency:** each `songId` flows through `acceptRip`, which is itself idempotent:
- already in manifest → `ready` (no enqueue).
- in-flight `resourceKey` with a live job → `inflight` (joins, no new queue file, no `persistQueue`).
- otherwise → new job + `inflight.set` + `persistQueue(job)` + `enqueue` → `queued`.
- `songById` miss → `unknown`.

For an **analog album** with multiple selected songs: the *first* song creates the job (`resourceKey = albumId`, one durable queue file). Siblings hit `inflight` → `inflight` status (no own queue file) and resolve via the manifest once the album rip completes. Re-POSTing the same collection is a no-op for already-ripped / in-flight songs.

> ⚠️ `queued` means *enqueued*, **not** guaranteed to succeed. Analog-file-missing / `Library.xml`-miss failures surface later as job phase `error`. The UI must say "enqueued — may fail later" and reconcile via a manifest refresh.

### `rippedAt` — manifest staleness stamp (Burn freshness)

Every manifest entry the server writes on a completed rip carries a **`rippedAt`** epoch-ms timestamp (the server's `Date.now()` at upload time): analog album completion (one stamp shared across all songs of the album from the single upload), digital/skill completion after the S3 upload, and the `POST /analysis` path when it mints a fresh entry. It is a **plain optional field** — older manifest entries that predate it still load (no required/schema check), and `GET /status` returns the full entry so the field is exposed.

The app uses it to detect a **stale burn**: `BurnStore.isFresh(_:dir:rippedAt:)` treats a ready burn as stale (⇒ re-download) when `manifest.rippedAt` is **newer** than the burn item's `downloadedAt`, while still keeping the file-size check. When `rippedAt` is nil (legacy entry) it degrades to the size-only check. This catches re-rips and analysis-overlay bpm/key updates, not just zero-byte / partial writes. See `apple/PocketDJ/State/{RipsStore.swift (ManifestEntry.rippedAt decode),BurnStore.swift (BurnItem.downloadedAt + isFresh)}`.

### Deliberately NOT added

No `/rip/async`, no `RIP_PROTOCOL` bump, no `/health` capability flag. For a single-user, lockstep-deployed server these are speculative. The app detects batch support by `/rip-collection` returning `404` and falls back to a per-song `/rip` loop — the only fallback worth keeping.

### LaunchAgent / deploy

- `scripts/launchd/com.pocketdj.ripserver.plist`: **no token is required.** The rip server runs **tokenless / public during development** for easy integration testing; `/rip-collection` uses the exact same permissive `authed()` gate as `/rip`. (Setting `RIP_TOKEN` later would gate *both* endpoints identically — `authed()` is shared — but it is not required and there is no `/rip-collection`-specific gate.)
- `scripts/update-ripserver.sh`: no code change — existing deploy path (`git pull` + `launchctl kickstart` + `/health`). Run after merging the rip-server edits to ship to the iMac.

---

## Feature 1 — Stream-through-rip

When Apple Music streaming *actually wins* a play, fire one unawaited `POST /rip` so the track is captured to S3 for later. Zero added playback latency; exact-once is server-guaranteed; the client guard is best-effort spam reduction.

### The play seam — `apple/PocketDJ/Playback/PlaybackCoordinator.swift`

The exact win point is in `play(_:)` (verified `:72–74`):

```swift
if await provider.tryPlay(song) {
    activeBackend = provider.backend
    return
}
```

Change: when `provider.backend == .appleMusic`, fire the rip **before** `return`:

```swift
if await provider.tryPlay(song) {
    activeBackend = provider.backend
    if provider.backend == .appleMusic {
        Task { await self.ripProvider.requestAsyncRip(song.id) }
    }
    return
}
```

- Plain `Task`, **not** `Task.detached` — `requestRipIfNeeded` is `@MainActor` and `Task` inherits the actor; detached would needlessly hop. The await chain that started playback has already completed, so this adds zero latency.
- `song.id` is the rip-server `songId` — all `POST /rip` needs.
- The coordinator already holds `ripProvider` (`:25`) which holds `rips`. No new wiring.

### Provider delegation — `apple/PocketDJ/Playback/RipServerPlaybackProvider.swift`

```swift
func requestAsyncRip(_ songId: String) async { await rips.requestRipIfNeeded(songId) }
```

Keeps the rip policy with the rip provider; the provider already owns `rips`.

### Fire-and-forget primitive — `apple/PocketDJ/State/RipsStore.swift`

Add a **synchronous** in-flight guard and the request method:

```swift
private var requesting: Set<String> = []

func requestRipIfNeeded(_ songId: String) async {
    // (a) cheap MainActor guard — early return
    if cachedURL(songId) != nil { return }
    if let p = jobs[songId]?.phase, [.queued, .searching, .ripping, .streaming, .uploading].contains(p) { return }
    if requesting.contains(songId) { return }
    // (b) synchronous insert BEFORE the await closes the guard race
    requesting.insert(songId)
    defer { requesting.remove(songId) }
    // (c) POST /rip — reuse ensureURL's request building (:174–184); never throws
    do {
        guard hasServer else { return }
        var post = URLRequest(url: URL(string: "\(serverUrl)/rip")!)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "content-type")
        applyAuth(&post, token: token)
        post.httpBody = try JSONSerialization.data(withJSONObject: ["songId": songId])
        let (data, _) = try await session.data(for: post)
        if let job = try? JSONDecoder().decode(Job.self, from: data) { jobs[songId] = job }
    } catch { /* swallow — F1 is best-effort */ }
}
```

Key properties:
- The cheap guard runs **before** any network call (cuts popular-song spam at the cheapest point).
- The `requesting` Set is inserted **synchronously before the first `await`**, closing the race the guard+POST would otherwise have across the suspension point — truly single-flight *per process*.
- `URLSession.data(for:)` *suspends* the actor, it does not block it.
- Never throws to the caller.

**Server is the cross-process / restart backstop:** the manifest skip (`:402`) + `inflight` join (`:405`) guarantee exact-once even across app restarts or multiple devices. The client `requesting` Set is purely spam reduction.

No new server endpoint — `POST /rip` already satisfies async + idempotent + durable + non-blocking.

---

## Feature 2 — Rip (collection) + Burn (collection)

### Collection resolvers — `apple/PocketDJ/State/CollectionsStore.swift`

Centralized pure resolvers (all deduped, text/note nodes excluded), shared by both Rip and Burn:

```swift
func songIds(forPlaylist id: String) -> [String]  // catalog().songs(inPlaylist:).map(\.id)
func songIds(forPocket id: String)   -> [String]  // catalog().resolvePocketSongs(id, seen:).map(\.id)
func songIds(forSetlist id: String)  -> [String]  // setlist.tracks.filter { $0.isText != true }.map(\.songId)
func songIds(forSource id: String)   -> [String]  // source.songIds
```

`CollectionCatalog` already skips `.text` / `.note` nodes when resolving playlists/pockets, and `isText` filters setlist cues — so no bogus id leaks into the batch. `404 'unknown'` is the server backstop.

### Feature 2 Rip — app side, `apple/PocketDJ/State/RipsStore.swift`

```swift
func ripCollection(_ songIds: [String]) async -> BatchRipResult
```

- Dedupe `songIds`, `POST /rip-collection { songIds }`, decode the per-song results, update `jobs[...]` for `queued`/`inflight` entries, return counts.
- If the POST `404`s (older server): fall back to looping `requestRipIfNeeded` per song and synthesize counts.

`BatchRipResult` carries the per-song statuses + counts for partial-success UI.

### Feature 2 Burn — NEW store `apple/PocketDJ/State/BurnStore.swift`

A new `@Observable @MainActor` store mirroring the `CollectionsStore` / `EditsStore` durable-JSON pattern. Runs a **serial, one-by-one download queue keyed by `songId`**, downloading **only already-ripped songs** — it never blocks on a 30-min `ensureURL`.

#### Local storage layout

- **Index file:** `Application Support/pocketdj-burns.json` — the **machine-readable source of truth** a future live-mixer consumes (NOT the prose `.txt`). Versioned Codable `{ schemaVersion: Int, items: [BurnItem] }`. Atomic write on every mutation; decode-on-init; `launchURL()` with `PDJ_USE_FIXTURE` → `temporaryDirectory` test seam (verbatim `CollectionsStore` pattern).
- **Audio + sidecar files:** `Application Support/burns/` (new `RipsStore.burnsDirectory()`, `.applicationSupportDirectory`, `create: true`).
  - Digital audio: `<songId>.mp3`.
  - Analog audio: `<albumId>.mp3` — **one shared file per album**, reused across that album's songs.
  - Sidecar (always): `<songId>.txt`.

Keying by id eliminates the Artist-Title collisions (live vs studio takes, same title across albums) — the prior design's HIGH bug. Application Support (not Documents) keeps burned audio app-managed.

#### `BurnItem` — the OFFLINE / LIVE-MIX-ready data model

```swift
struct BurnItem: Codable {
    var songId: String
    var title: String
    var artist: String
    var audioFileName: String      // <songId>.mp3 (digital) | <albumId>.mp3 (analog)
    var sidecarFileName: String    // <songId>.txt
    var source: String             // "analog" | "digital"
    var bpm: Double?
    var musicalKey: String?
    var camelot: String?
    var durationMs: Int?
    var startMs: Int?              // analog: seek offset within the shared album mp3
    var bytes: Int
    var rippedAt: Double           // from ManifestEntry — staleness check
    var downloadedAt: Double
    var state: String              // queued | downloading | ready | error
    var error: String?
}
```

The analyzed `bpm`/`musicalKey`/`camelot`/`durationMs`/`startMs` are the values *actually used* — preferring `ManifestEntry` over catalog (as `SongRowView.effBpm`/`effKey`/`effCamelot` does). For analog, `startMs` is exactly the per-song seek offset the server already records at `rip-server.mjs:232`.

#### Non-blocking download primitive — `RipsStore.swift`

```swift
func downloadDataIfCached(_ song: (id: String, title: String, artist: String)) async throws -> (Data, ManifestEntry)?
```

Returns `nil` when `cachedURL == nil` (does **not** call the rip-on-demand `ensureURL` path); otherwise GETs the durable public-S3 mp3 bytes and returns them with the `ManifestEntry`. This decouples Burn from `downloadData(:261)`, which calls `ensureURL(allowLive: false)` and can poll up to 1800s per song (`:195`). Burn must never block on a live rip.

#### The burn queue

```swift
func burn(_ songs: [(id: String, title: String, artist: String)],
          lookup: (String) -> (IndexSong?, IndexAlbum?)) async
```

Processes items **sequentially**. For each song:

1. **Idempotency:** skip if `items[songId].state == .ready` **and** the audio file exists **and** file size == recorded `bytes` **and** `manifest[songId].rippedAt <= item.downloadedAt`. Re-download if the manifest is newer (re-rips / analysis-overlay bpm/key updates) or if the size mismatches (zero-byte / partial prior write).
2. **Not-ripped short-circuit:** if `rips.cachedURL(songId) == nil` → record `"not ripped — Rip first"` (or `"not ripped (no rip server)"` when `!hasServer`) and **continue**. Burn never calls `ensureURL`.
3. `state = .downloading`; publish bulk progress `{ done, total, label: "Artist — Title" }`.
4. `(data, entry) = try await rips.downloadDataIfCached((id, title, artist))`.
5. **Analog** (`entry.source == "analog"`): target = `<albumId>.mp3`; if it already exists from a sibling, **reuse** (no second download/write of the whole-album mp3). **Digital:** target = `<songId>.mp3`. Atomic write.
6. Write `<songId>.txt` via `buildSidecar` (human-readable companion).
7. `items[songId] = .ready` with file names + analyzed `bpm`/`musicalKey`/`camelot`/`durationMs`/`startMs` + `bytes` + `rippedAt` (from entry) + `downloadedAt`; `save()`.

Edge handling:
- **Partial success:** per-item `do`/`catch` → `state = .error` + message, **continue**.
- **Disk-full:** a write throwing `NSFileWriteOutOfSpaceError` aborts the remaining queue with one `"out of space"` summary (every remaining item would fail anyway).
- **Empty collection:** no-op.
- **`hasServer == false`:** still burns `cachedURL != nil` songs; reports the rest as `"not ripped (no rip server)"`.
- **Re-running burn:** re-downloads only stale / missing items (idempotent).

#### Sidecar builder — `BurnStore.buildSidecar`

```swift
static func buildSidecar(song: IndexSong, album: IndexAlbum?, entry: RipsStore.ManifestEntry?) -> String
```

Mirrors `burn-setlist.mjs` `buildSidecar` (`:171–223`) header order, as a **human** companion:

```
Artist — Title
============================================================ (60×)

BPM: …
Key: … (Camelot …)
Sentiment: <sentimentKeywords joined ", ">
Album: …

-- Song metadata --
…
-- Album metadata --
…
-- Raw JSON --
{ "song": …, "album": …, "manifestEntry": … }
```

- **Prefer** the `ManifestEntry` analyzed `bpm`/`musicalKey`/`camelot` over catalog values when present.
- The Raw JSON block embeds `{ song, album, manifestEntry }` so the prose header and the JSON agree on the analyzed values.
- Omit the burn-setlist "Segment (carved from raw rip)" block — Swift `IndexSong` has no pointer offsets; the analog seek offset lives in the burn **index** (`startMs`), not the sidecar.

#### Future-consumer seams (designed-for, NOT implemented)

```swift
func localURL(forSong songId: String) -> URL?   // ready item's audio URL ONLY if the file still exists
func remove(_ songId: String)                    // delete files + index entry
var totalBytes: Int                              // for eviction/cap policy
func reconcileOnLaunch()                         // prune items whose audio file vanished
```

- `localURL` existence-checks so a future player degrades gracefully instead of getting a dead URL.
- For analog, the consumer reads `item.startMs` and seeks into the shared album mp3.
- The burn index is the enumerable, machine-readable catalog of offline-available tracks keyed by `songId`, carrying `bpm`/`key`/`camelot`/`durationMs`/`startMs` a live-mixer reads directly (no prose parsing).
- `remove` + `totalBytes` + `reconcileOnLaunch` make the layout **eviction-ready** (LRU/cap is future, but the hooks exist).
- A future offline-playback path feeds `localURL` + `startMs` into `PlayerEngine.load(url:live:startMs:title:artist:)` — which already accepts any URL + `startMs`, so no new playback API is needed.

#### Rip vs Burn separation

- **Rip** = server-side only (`POST /rip-collection` → durable queue → S3 + manifest). No local download, no blocking.
- **Burn** = purely app-side download of already-ripped songs + local persistence + human sidecar. It triggers ripping only *indirectly* (optionally enqueueing not-yet-ripped songs via `ripCollection` for a later pass), never blocking the burn queue on a live rip.

### UI wiring

| View | Seam | Rip target | Burn target |
|---|---|---|---|
| `apple/PocketDJ/Views/SetlistDetailView.swift` | toolbar primaryAction (~`:74`), new Menu | `songIds(forSetlist:)` | resolved tuples + lookup |
| `apple/PocketDJ/Views/PlaylistsView.swift` — `PlaylistDetailView` | existing `playlist-menu` Menu (~`:249`) | `songIds(forPlaylist:)` | same |
| `apple/PocketDJ/Views/PlaylistsView.swift` — `IndexPlaylistDetailView` | action Section (~`:145`) | `songIds(forSource:)` | same |
| `apple/PocketDJ/Views/PocketsView.swift` — `PocketDetailView` | existing `pocket-menu` Menu (~`:187`) | `songIds(forPocket:)` | same |

Each menu gets **"Rip collection"** + **"Burn collection"**:
- **Disable** both when the collection has no resolvable songs (empty / itemCount / `isEmpty` guard).
- **Gate Rip** on `rips.hasServer`.
- **Decision:** `IndexPlaylistDetailView` ("From your sources", read-only) **does** get Rip/Burn — source playlists are a primary bulk-rip target.
- **Bulk progress + partial-success summary:**
  - Rip: `"Ripped 8 of 10 — 2 unrippable"` framed as **"enqueued — completes over time"** (because rip is real-time + concurrency-1) with a **Refresh** action that calls `rips.refreshManifest()` to reconcile final ready/failed counts.
  - Burn: `"Burned 6 of 10 — 4 not yet ripped"`.

### Composition root + launch wiring

- `apple/PocketDJ/PocketDJApp.swift`: construct `BurnStore` in the composition root (~`:14–37`) passing the **shared** `rips` instance, inject via `.environment` (~`:43–50`). F1 needs no new wiring here (coordinator → `ripProvider` → `rips` already).
- `apple/PocketDJ/Views/RootView.swift`: in the launch `.task`, call `burnStore.reconcileOnLaunch()` after the existing `rips.refreshManifest()` (~`:66`), and wire the late-bound `BurnStore` catalog-lookup closure (mirror `collections.app = app` at ~`:59`) so `buildSidecar` can resolve `IndexSong` / `IndexAlbum`.

---

## What's reused

- **`scripts/rip-server.mjs` accept logic** (`:397–412`, verified): unknown→404, manifest-cached skip, single-flight `inflight` join by `resourceKey`, job create + `persistQueue` + `setPhase` + `enqueue`. Factored into `acceptRip`; `/rip` keeps its byte-identical response.
- **Durable on-disk queue:** `queueFile`/`persistQueue`/`clearQueue` (`:132–136`), `enqueue`/pump concurrency-1 (`:138–148`), `resumePending` crash recovery (`:151–171`). Batch Rip reuses verbatim — one file per `songId`, idempotent across restart. No second queue.
- **S3 upload + manifest indexing:** `runAnalogJob` (`:207–241`) uploads `rips/<albumId>.mp3` + registers every song with its `startMs` (`:229–234`); `runDigitalJob` (`:248–291`) uploads `rips/<songId>.mp3`; `saveManifest` (`:97–101`). "Rip AND upload to S3" is already the normal rip behavior — batch Rip needs zero new upload code. The analog per-song `startMs` (`:232`) is exactly the seek offset Burn records.
- **`POST /rip` idempotency** as the F1 fire-and-forget backstop (non-blocking + idempotent + durable).
- **`RipsStore.cachedURL`** (`:119`) + the public-S3 manifest (`refreshManifest:104`, `manifest:76`, `ManifestEntry` incl. `source`/`startMs`/`durationMs`/`bpm`/`musicalKey`/`camelot`/`analyzed` at `:48–59`) — "already ripped" source of truth for F1 idempotency, Burn's download-only-if-cached gate, and the analyzed values copied into the burn index.
- **`RipsStore.serverUrl`/`token`** (`:90–91`), `applyAuth` (`:304`), `session`, the request building in `ensureURL` (`:174–184`) — reused by `requestRipIfNeeded` + `ripCollection`. The `jobs` map (`:78`) is the F1 client-side guard alongside the new synchronous `requesting` Set.
- **`RipsStore.downloadBaseName`** (`:292`) — reused for the human sidecar header line only (files are keyed by id).
- **`CollectionCatalog`** (`songs(inPlaylist:)`/`resolvePocketSongs`/stats) + `CollectionsStore.catalog()` (`:270`) — pure collection→[`IndexSong`] resolution; cycle-guarded, deduped, album/pocket-expanded, text/note excluded.
- **`CollectionsStore`/`EditsStore` durable-JSON pattern** (`defaultURL`/`launchURL`/atomic save/decode-on-init/`PDJ_USE_FIXTURE` seam) — the template for `pocketdj-burns.json`.
- **`.claude/skills/burn-setlist/burn-setlist.mjs` `buildSidecar`** (`:171–223`) — the `.txt` format Burn mirrors.
- **`PlaybackCoordinator.play` win point** (`:72`, verified) — F1 hook with zero added latency. Coordinator already holds `ripProvider` (`:25`) → `rips`.
- **`PlayerEngine.load(url:live:startMs:title:artist:)`** — future offline-playback consumer of Burn's local file URLs + analog `startMs`; no new playback API needed.
- **SwiftUI detail-view toolbar/menu seams** (listed in UI wiring).
- **`PocketDJApp` `.environment` DI** (~`:43–50`) — where `BurnStore` is constructed + injected with the shared `rips`.

---

## Tests

- `scripts/test/stream-e2e.mjs` + `scripts/test/fake-rip-worker.mjs`: add a `/rip-collection` e2e using `RIP_WORKER=fake-rip-worker.mjs` (no S3 / Audio Hijack). POST a mix of: an unknown id, an already-manifest id, fresh digital ids, and **multiple songs of one analog album**. Assert per-song statuses (`unknown`/`ready`/`queued`/`inflight`), that exactly **one** durable queue file exists per analog album (leader) with siblings `inflight` (no own queue file), and that a tokenless server accepts the POST (public). Assert each completed rip writes `rippedAt` into its manifest entry.
- Native unit tests ([`apple/Tests/Unit/BurnStaleTests.swift`](../../apple/Tests/Unit/BurnStaleTests.swift)): `ManifestEntry` decodes the optional `rippedAt` (backward-compatible when absent); `BurnStore.burn` re-downloads when `manifest.rippedAt` is newer than the burn's `downloadedAt`, stays fresh otherwise, and falls back to the size-only check when `rippedAt` is nil; the fallback-loop status buckets match the batch `/rip-collection` vocabulary. (Add an F1 test that `requestRipIfNeeded` fires at most **one** POST on a rapid double-call via the synchronous `requesting` Set and never throws.)

---

## Risks

- **F1 amplification on popular songs:** mitigated by the synchronous `requesting` Set (per process) + server manifest/inflight dedup (cross-process). Worst case is a few redundant POSTs that the server collapses; never a duplicate rip.
- **`/rip-collection` amplification:** accepted by design. The endpoint is **public** (tokenless) during development to keep integration testing frictionless, and there is **no id cap** — it is async and the durable queue (concurrency-1) absorbs any burst, so a large or repeated POST just enqueues idempotent jobs the worker drains over time. `acceptRip` dedup (manifest skip + single-flight `inflight` join) means re-POSTing the same collection is a no-op for already-ripped / in-flight songs. (A `RIP_TOKEN`, if ever set, gates `/rip` and `/rip-collection` identically via the shared `authed()` gate — not required today.)
- **`queued` ≠ success:** analog-file-missing / `Library.xml`-miss surface later as job phase `error`. UI must say "enqueued — may fail later" and reconcile via manifest refresh.
- **iOS purging Application Support under storage pressure** without touching the index: mitigated by `reconcileOnLaunch()` + existence-checked `localURL`.
- **Stale / corrupt burns:** size + `rippedAt` staleness check re-downloads when the manifest is newer or bytes mismatch (catches re-rips, analysis-overlay updates, zero-byte writes).
- **Network type:** F1 rips + Burn downloads run full mp3s over Tailscale with no Wi-Fi-only / "pause on cellular" guard. Deferred (Tailscale to a home iMac is typically Wi-Fi) but noted.
- **Disk-full mid-burn:** early-abort with a single "out of space" summary rather than N identical failures.

---

## Explicitly deferred

- **Offline playback** — not implemented. The storage layout, `localURL(forSong:)`, the burn index (`pocketdj-burns.json`), and analog `startMs` are all built to be consumed by a future `PlayerEngine.load(url:startMs:)` path, but no offline player is wired.
- **Live mixing** — not implemented. The burn index is the machine-readable catalog (per-item `bpm`/`key`/`camelot`/`durationMs`/`startMs`) a future live-mixer will enumerate, but no mix engine exists.
- **Eviction / size cap** — not implemented. The hooks (`totalBytes`, `remove(_:)`, `reconcileOnLaunch()`) make the layout eviction-ready; an LRU/cap policy ships with offline playback.
- **Metered-connection guard** — deferred (see Risks).

---

## Open questions (recommendations)

1. **Auto-enqueue not-yet-ripped songs during Burn?** Recommend yes (more useful) but never block the burn queue on the result — the current design does exactly this. Confirm the UX wording.
2. **Eviction/cap policy now?** Recommend defer (layout is eviction-ready).
3. **Analog burn = `<albumId>.mp3` shared + `startMs` seek?** Recommend yes (collision-free, no duplicate download). Confirm the future player is fine seeking by `item.startMs` into the shared file rather than per-song carved files.
4. **F1 suppressed when `hasServer == false`?** Recommend a subtle Settings hint to configure the rip server (so users discover stream-through-ripping) rather than a per-play prompt.

---

Relevant file paths:
- `scripts/rip-server.mjs` (acceptRip refactor + `/rip-collection`; `rippedAt` written into every manifest entry on rip completion)
- `apple/Tests/Unit/BurnStaleTests.swift` (NEW — `rippedAt` decode + Burn staleness + fallback-bucket tests)
- `apple/PocketDJ/Playback/PlaybackCoordinator.swift` (F1 win point `:72`)
- `apple/PocketDJ/Playback/RipServerPlaybackProvider.swift` (`requestAsyncRip`)
- `apple/PocketDJ/State/RipsStore.swift` (`requesting` Set, `requestRipIfNeeded`, `ripCollection`, `downloadDataIfCached`, `burnsDirectory`)
- `apple/PocketDJ/State/BurnStore.swift` (NEW)
- `apple/PocketDJ/State/CollectionsStore.swift` (`songIds(for…)` resolvers)
- `apple/PocketDJ/Views/{SetlistDetailView,PlaylistsView,PocketsView}.swift` (menu seams)
- `apple/PocketDJ/PocketDJApp.swift` + `apple/PocketDJ/Views/RootView.swift` (DI + launch reconcile)
- `scripts/test/{stream-e2e.mjs,fake-rip-worker.mjs}` (tests)