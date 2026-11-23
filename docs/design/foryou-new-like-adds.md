# For You ▸ New: a 👍 adds the record

**Status:** designed (feat/foryou-new-like-adds), not implemented
**Owner ask (Levi, 2026-11-23, verbatim):**
> "in For You New, when you like a pick it should auto add it to your library, otherwise it's
> training the algo which is good but not building my collection"
>
> "and resurface any ones previously liked but not added so I can actually add them"

## 0. What happens today, and why records vanished

| Piece | iOS | Android |
|---|---|---|
| Screen | `apple/PocketDJ/Views/ForYouDetailViews.swift` `NewReleasesView` | `android/.../screens/foryou/NewReleasesScreen.kt` (`NewReleasesPresentation` = pure helpers) |
| 👍/👎 | `RecFeedbackButtons(songId: item.feedbackId, scope: "new")`, **no `onAccept`** | `RecFeedbackButtons(item.feedbackId, SCOPE, …)`, **no `onAccept`** |
| Verdict id | `ReleaseFeedItem.feedbackId` = `rel:<albumStoreId>` (or `relartist:<artistId>` when no release id) | same |
| After 👍 | `offered()` drops everything in `acceptedInScope("new")` from **both** sections, permanently | `NewReleasesPresentation.offered()` does the same |
| Row tap | pushes `AppleMusicAlbumRef` → `AlbumPreviewView` (the add path lives there) | opens `music.apple.com/us/album/<id>` in an external app; **Android has no album preview screen** |
| Album add | `RipsStore.discoverAddAlbum(hit, library:, intent: .libraryOnly)` from `AlbumPreviewView.addAlbum()` | `DiscoverAddController.addAlbum(hit, AlbumAddIntent.LIBRARY_ONLY)` exists (Discover uses `AND_PREPARE_COPIES` via `BrowseGraph.discoverAddAlbum`) |
| Feed cache | `ReleaseFeedService.entries`: **one entry per artist, the LATEST release only**, 30-day window at read time | same |

So a 👍 wrote a verdict, the row was removed by `offered()`, and nothing was ever added. And
because the feed cache keeps only an artist's *latest* release, a 👍'd record is lost from the
cache entirely the moment that artist puts out anything newer, and from the screen after 30 days
anyway. That last point means resurfacing needs its own metadata (section 3), because the feed
cache can't supply it.

### What "add to the library" means (both platforms, already implemented)

One add does two things, and both platforms already do both:

1. **Apple Music library write.**
   - iOS: `MusicLibraryContributor.addAlbumToLibrary` → `AppleMusicProvider`, which goes through
     `AppleMusicLibraryAddFallback.run`: native `MusicLibrary.add`, and if that throws (the iOS 27
     beta `MPErrorDomain#0` regression) the web API `POST /v1/me/library`. The result is an honest
     `AppleMusicLibraryWriteOutcome`: confirmed / confirmedWeb / unconfirmed / failed / skipped.
     macOS cannot write, so the album page opens Music.app instead.
   - Android: `AppleMusicApi.addToLibrary(ALBUMS, [id])`, which is the same web
     `POST /v1/me/library` → token `"confirmed (web)"` or `"Apple Music write failed: …"` /
     `SKIPPED_NO_CONNECTION`.
2. **PocketDJ catalog citizenship.** The tracks are expanded (MusicKit / REST `albumTracks`, else
   the rip server's `/album-tracks`) and one batched provisional album `amrec_album_<id>` plus
   `amrec_<trackId>` songs are written to `DiscoverAddsStore` (this store syncs). That makes the
   release **owned** under the existing `ReleaseFeedService.ownershipProbe` /
   `ReleaseOwnershipProbes.ownership`. Already-owned tracks supersede instead of duplicating
   (`AppModel.injectDiscoverAlbumBatch` / `repo.onSupersede`), which is how "Add remaining (n)"
   works: the add is idempotent over the tracks you already have.

`.libraryOnly` / `LIBRARY_ONLY` captures no audio. The like-add must use this intent, never
`.andPrepareCopies`. Levi reported on 2026-08-07 that an album add on the New screen started
ripping, and that must not come back.

## 1. Behaviour

### 1.1 👍 on a New row = verdict + the album page's add

- The tap goes through `RecFeedbackStore.toggle` exactly as today (same `rel:<id>`, scope `new`,
  surface `.tile`), so the taste signal, tombstones and sync are unchanged.
- `onAccept` runs **only when the verdict landed as `.accepted`**. `RecFeedbackButtons` already
  enforces this on both platforms (tapping a lit 👍 is an undo and must never add again). It
  calls the **same add the album page uses**:
  - iOS: a new `RipsStore.addRelease(ref:trackCount:library:) -> ReleaseAddReport`, which is
    `discoverAddAlbum(_, library:, intent: .libraryOnly)` returning a report. `AlbumPreviewView.addAlbum()`
    is changed to call it too, so there is one implementation. The macOS `openURL` stays in the
    view and is **not** fired from a 👍: auto-opening Music.app on every like would be hostile.
    On macOS the like still records the PocketDJ-side add, and the Liked row offers "Open in Music".
  - Android: `DiscoverAddController.addAlbum(hit, AlbumAddIntent.LIBRARY_ONLY)`, called through the
    existing `BrowseGraph.discoverController`.
- `relartist:` rows (no release id) cannot be added. They keep today's pure-feedback 👍. This is
  the only case where a 👍 is pure feedback.
- The add runs in a screen-independent orchestrator (`NewReleaseLikeAdder`, section 4), so leaving
  the screen mid-add doesn't cancel it.

### 1.2 What the row does while the add runs and after it finishes

`offered()` keeps removing accepted releases from **Out now / Coming soon**. Instead of vanishing,
an accepted release that is not yet added shows in a new top section,
**"Liked — not added"**, rendered from the selection in section 2. In-flight rows show
"Adding…" with a spinner there. So a 👍 moves the row up into "Liked" with a spinner. On
success the release becomes owned, the selection drops it, and it disappears from the screen
because it is in the library. On failure it stays in "Liked" with the error.

### 1.3 Outcomes → row state (`LikeAddState`)

| Report | Row in "Liked — not added" | Auto-retry? |
|---|---|---|
| tracks recorded **and** write proven (`confirmed`/`confirmedWeb`; Android `"confirmed (web)"`) | gone (owned). A 24 h `added` grace hides it while the catalog rebuild or sync catches up | — |
| tracks recorded, write **not** proven (failed / unconfirmed / skipped-but-could-write) | stays: "Added to PocketDJ — Apple Music add failed: \<reason\>" + **Retry** (calls `retryAlbumLibraryWrite`, gated by the existing `AlbumLibraryWriteRetry.needsRetry` / `DiscoverRetry.needsRetry`) | no |
| macOS skip (platform can't write) | gone (owned in PocketDJ). Nothing pending | — |
| nothing recorded, offline (no MusicKit and no server, or a transport error) | stays: "Will add when you're back online" | **yes**: sweep on launch/foreground |
| nothing recorded, other failure (e.g. "Couldn't read the album's tracks") | stays: the honest message + **Retry** | no |
| **pre-order**: write proven, nothing recorded (pre-release expansion is empty or placeholder) | stays in **Coming soon** with a "Pre-added ✓" badge (not in Liked). `awaitingRelease` | **yes**: the sweep retries the full add once `now ≥ releaseAt` |
| pre-order: write failed/skipped | `awaitingRelease`, shown in Liked as "Coming <date> — will add on release day" | **yes**, on release day |

The verdict is recorded before the add starts and is never rolled back on failure.

**Error copy.** Reuse `RipsStore.libraryWriteNotice(_:noun:)` (iOS) and the `LibraryWrite` /
`DiscoverAddWording` strings (Android) so failures read exactly as they do on the album page.
iOS: the report carries the error string itself. Do not read `rips.discoverError` after the
await, because that variable is shared and Add-all or the album page racing it would show the
wrong row's error.

### 1.4 Pre-orders

The add is attempted right away because Apple Music supports pre-adds. If the write lands, the
Apple Music side is done, and PocketDJ catalog citizenship follows on release day: the sweep
re-runs the same add, the write is idempotent, and the tracks are now real. Track metadata is
then healed by the existing `refreshProvisionalAlbums` / `DiscoverAddsStore.needsRefresh` path.
If the write can't land before release, the add is queued and runs on release day.

### 1.5 Undo

Un-👍 (tapping the lit thumb) clears the verdict, cancels a queued (not yet started) add, and
**never removes anything from the library**. An in-flight add completes. Once a release is added
it leaves the screen, so its thumb isn't there to tap. The only place an un-👍 can follow an add
is the album page or a lingering error row, and there the label is already "Undo more like
this", which says nothing about the library. **No new copy is needed.** Removing an added record
stays the existing "Remove from Library" action.

### 1.6 Partial ownership

`ownsRelease` is an album-level answer, so a part-owned album is "not owned" and shows in Liked.
Its Add runs the same idempotent batch (owned tracks supersede), which is "Add remaining". The
row button says "Add". Labelling the remaining count would need a per-row track expansion, which
the album page already does when he taps through.

### 1.7 Offline

Covered by the `offline` row state above. The verdict is local and syncs later. The sweep
(`NewReleaseLikeAdder.sweep(nowMs:)`) runs on app launch, on foreground, and when the New screen
appears, and retries `offline` and due `awaitingRelease` items, **at most once per item per 6 h**
and sequentially. It never retries `failed` items. Those wait for his Retry tap.

## 2. Resurfacing: "Liked — not added"

### 2.1 Selection (pure, the heart of the feature)

```
likedNotAdded(
  accepted:      [feedbackId: acceptedAtMs]     // RecFeedbackStore.acceptedInScope("new")
  meta:          [storeId: LikedRelease]        // LikedReleasesStore (section 3)
  owns:          (ReleaseIdentity) -> Bool      // the SAME probe the feed uses
  ownsVersion:   (artistId, artistName, title) -> Bool
  writeNeedsRetry: (storeId) -> String?         // provisional album exists && token not proven (+ canAddToLibrary)
  attempts:      [storeId: LikeAddAttempt]
  inFlight:      Set<storeId>
  nowMs
) -> (rows: [LikedRow], needsHydration: [storeId])
```

Rules, in order:

1. Only `rel:` ids. `relartist:` ids are skipped because they can't be added.
2. No `meta` → put the id in `needsHydration`, render nothing for now.
3. **Owned** (`owns(identity) || ownsVersion(...)`), *unless* `writeNeedsRetry` → drop. If it's
   owned and the Apple Music write is unproven → keep, as a "Retry Apple Music" row. These are
   the same two predicates the feed uses, so "added by any path" (the album page, Discover, a
   Music.app add that came in through the library source, another device's Discover add via
   sync) removes it with no extra bookkeeping.
4. `attempt.state == .added` and `nowMs - attempt.atMs < 24h` → drop (catalog/sync lag grace).
5. `attempt.state == .awaitingRelease` with a proven write → not in Liked. It renders in Coming
   soon as "Pre-added". Once `releaseAt + 3 days` has passed and it still isn't owned, it comes
   back into Liked (the sweep's release-day add evidently didn't land).
6. **No age limit.** A like from six months ago that was never added still shows.
7. Order: in-flight and errors first, then most recently liked first (`acceptedAtMs` desc).

### 2.2 The section

- Header "Liked — not added" (`new-liked-section`) with a trailing **Add all (n)**
  (`new-liked-add-all`). It's disabled while any add is in flight. It runs **sequentially**:
  that's kinder to the Apple edge limiter (the feed already measured 429 bursts), and it keeps
  the error-to-row attribution exact.
- Each row looks like a release row (art, title, artist, kind, date) plus the state line and a
  trailing **Add** / **Retry** / spinner. The lit 👍 stays as the undo. On iOS, tapping the row
  pushes `AlbumPreviewView` exactly as today, which shows "Add remaining (n)" and ticks.
- The section renders even when the 30-day feed is empty: the empty state shows only when the
  feed **and** Liked are both empty.
- **Default is surface-with-Add, never silent bulk add.** Levi said "so I can actually add them".
  Retroactive likes are not auto-added. Only a *new* 👍 auto-adds. The Add all button is the
  bulk path, and he presses it himself.

### 2.3 Transport / tile

- ▶/🔀 keep playing `liveOutNow` only. Liked rows are not in the queue: Liked can hold old
  records, and New's queue means new music.
- The New tile badge (`ForYouGrid.tiles` / Android `ForYouGrid`) is **unchanged in this pass**.
  A follow-up can add a "· n liked" sub-line. Leaving it out keeps Android's `ForYouGrid.kt`
  (shared with the parity program) untouched.
- CarPlay (`CarPlayForYou.newReleaseItems`) is unchanged. It has no row thumbs, so no like-add
  starts there.

## 3. Data

### 3.1 Sync shapes: unchanged

`RecFeedbackStore.Decision`/`Document` and the `RecFeedbackWire` upload are **not touched**. The
verdict log stays the single synced source of truth for *what he liked*. `DiscoverAddsStore`
(synced) stays the source of truth for *what was added*. No new synced document.

### 3.2 `LikedReleasesStore`: a per-install metadata cache (new, unsynced)

A small JSON file, `liked-releases.json` (iOS Application Support next to the release-feed
cache; Android `filesDir`). It is a **cache, not state**: deleting it loses nothing, because
hydration rebuilds the metadata from the verdict ids. Both platforms use the same JSON shape so
fixtures can be shared:

```json
{
  "schemaVersion": 1,
  "releases": [{
    "storeId": "1790000000",
    "artistId": 12345, "artistName": "Larry June",
    "title": "Who Coppin", "artworkUrl": "https://…/{w}x{h}bb.jpg",
    "releaseAtMs": 1763856000000, "kind": "album", "trackCount": 12, "explicit": true,
    "likedAtMs": 1763900000000,
    "attempt": { "atMs": 1763900001000, "state": "failed",
                 "message": "Couldn’t read the album’s tracks — try again.",
                 "writeToken": "failed: …" }
  }]
}
```

- `state` ∈ `adding | added | failed | offline | awaitingRelease`. Stored as a string, under the
  never-rename-a-shipped-rawValue rule. Decoding is lenient: every field except `storeId` is
  optional, unknown keys are ignored, and a bad row is skipped instead of failing the file (the
  same pattern as `LenientDecision` / `ReleaseFeedService.Document`).
- `adding` is never trusted across launches. On load it becomes `offline`, so a crash mid-add
  gets retried by the sweep instead of spinning forever.
- **Written at like time** from the `ArtistReleaseEntry` in hand. This is the common path and
  costs no network.
- **Hydrated** for accepted `rel:` ids that have no cached metadata: likes from before this
  feature, likes made on another device, or a lost cache. It uses the **same transport the feed
  already uses** (iOS `ReleaseFeedTransport` / `MusicKitCatalogTransport`; Android
  `AppleMusicReleaseTransport`):
  `GET /v1/catalog/us/albums?ids=<≤50 comma-separated>`. From `data[]` it reads `id`,
  `attributes.{name, artistName, releaseDate, artwork.url, trackCount, contentRating, isSingle,
  isCompilation}` and `relationships.artists.data[0].id` (albums include `artists` by default).
  It reuses `ArtistsCatalogResponse.parseReleaseDate`, so a bare year comes back as nil, plus
  the feed's kind mapping and backoff. An id Apple doesn't return (pulled from the catalog) is
  stored as a `tombstoned: true` row and never asked about again. Hydration runs when the New
  screen appears and on the sweep. It is never a fetch on the render path.
- Pruning: rows whose verdict is no longer `accepted` (cleared or flipped) are dropped on the next
  sweep. Size is bounded by his like count.

## 4. Code changes

### 4.1 iOS (`apple/`, XcodeGen: new files under `PocketDJ/` are picked up by `xcodegen generate`)

| File | Change |
|---|---|
| `PocketDJ/Services/Recommendations/LikedReleases.swift` **(new)** | `struct LikedRelease: Codable` + `LikeAddAttempt` + `enum LikeAddState: String`. `enum LikedReleaseSelection { static func likedNotAdded(...) }` (pure, section 2.1). `struct AlbumsCatalogResponse: Decodable` + `entries()` for hydration. `LikedRelease.init(entry: ArtistReleaseEntry, likedAtMs:)`, `.identity: ReleaseIdentity`, `.albumRef: AppleMusicAlbumRef`. |
| `PocketDJ/State/LikedReleasesStore.swift` **(new)** | `@MainActor @Observable final class LikedReleasesStore`: `releases: [String: LikedRelease]`, `revision`, `upsert`, `setAttempt`, `prune(keepingAccepted:)`, debounced atomic save (copy the `RecFeedbackStore` save skeleton), the `PDJ_USE_FIXTURE` seam. Not added to CloudSync. |
| `PocketDJ/State/NewReleaseLikeAdder.swift` **(new)** | `@MainActor @Observable final class NewReleaseLikeAdder`. `protocol ReleaseAddPort { func add(_ r: LikedRelease) async -> ReleaseAddReport; func retryWrite(_ r: LikedRelease) async -> ReleaseAddReport; var isOffline: Bool { get } }` with a production `RipsReleaseAddPort(rips:, library:)`. API: `liked(_ entry: ArtistReleaseEntry)` (upsert meta + start the add), `add(storeId:)`, `addAll(_:)` (sequential), `retry(storeId:)`, `unliked(storeId:)` (cancel if queued), `sweep(nowMs:)`, `hydrateMissing(acceptedIds:)`. `inFlight: Set<String>` guards double-taps. Pure `static func state(for report: ReleaseAddReport, releaseAtMs:, nowMs:) -> LikeAddState` implements the table in 1.3. |
| `PocketDJ/State/RipsStore.swift` | Add `struct ReleaseAddReport { write: AppleMusicLibraryWriteOutcome; recorded: Bool; error: String? }` and `func addRelease(ref: AppleMusicAlbumRef, trackCount: Int?, library:) async -> ReleaseAddReport`. **Refactor** `discoverAddAlbum` so it computes its error locally and returns the report through an internal function, still assigning `discoverError` for existing callers. One body, no second implementation. |
| `PocketDJ/Views/AlbumPreviewView.swift` | `addAlbum()` calls `rips.addRelease(...)` (keeps the macOS `openURL` and the `errorText` from the report). |
| `PocketDJ/Views/ForYouDetailViews.swift` (`NewReleasesView`) | Add `@Environment(NewReleaseLikeAdder.self)` and `@Environment(LikedReleasesStore.self)`. Pass `onAccept: { adder.liked(item.entry) }` to the row's `RecFeedbackButtons` when `item.entry.releaseId != nil`. Add the `likedSection` above Out now. The empty state checks feed and liked. Coming-soon rows that are awaiting release with a proven write render a "Pre-added" badge. `.task { adder.hydrateMissing(...); adder.sweep(...) }`. Update the stale doc comments ("a 👍 is pure feedback"). |
| `PocketDJ/PocketDJApp.swift` | Construct `LikedReleasesStore` + `NewReleaseLikeAdder` next to `releaseFeed` (~line 813). Inject them into the environment. Run `sweep` on launch and on `scenePhase == .active`. In fixture mode use a deterministic `FixtureReleaseAddPort` (succeeds and injects the provisional album, so ownership flips) so the UI suite never touches MusicKit. |
| `PocketDJ/Services/Recommendations/ReleaseFeedService.swift` | Add `func fetchAlbums(ids:) async -> [LikedRelease]` (or a static helper) on the existing transport + backoff. No change to `feed()`. Extend `uiFixtureEntries` with a 4th fixture release that is **accepted but not owned** (`rel:9000000004`, "Liked Record") whose `RecFeedbackStore` fixture verdict is seeded by the same fixture seam. |

### 4.2 Android (keep it local: everything new is in new files under `screens/foryou/` or `data/recs/`)

| File | Change |
|---|---|
| `data/recs/LikedReleases.kt` **(new)** | `@Serializable data class LikedRelease`, `LikeAddAttempt`, `enum class LikeAddState(val raw)`, `object LikedReleaseSelection { fun likedNotAdded(...) }` (identical rules), `object AlbumsCatalogParser` (hydration decode, reusing `ReleaseFeedModels.parseReleaseDate`). |
| `data/recs/LikedReleasesStore.kt` **(new)** | File-backed, `StateFlow<State>` with a `revision`, lenient `Json { ignoreUnknownKeys = true }`, and `adding` → `offline` on load. Not registered with cloud sync. |
| `screens/foryou/NewReleaseLikeAdder.kt` **(new)** | Same API as iOS. `interface ReleaseAddPort`. Production impl wraps `graph.browseGraph.discoverController.addAlbum(DiscoverAlbumHit(appleMusicId, title, artist, artworkUrl, trackCount, url = albumUrl(id), releaseDate), AlbumAddIntent.LIBRARY_ONLY)` and `retryAlbumLibraryWrite(...)`. Runs on `app.appScope + Dispatchers.IO` so it survives navigation. Obtained through `NewReleaseLikeAdder.get(graph)` (a process singleton in this file). **No `BrowseGraph.kt` edit** in this pass, to avoid conflicts with `feat/android-parity2`. Hydration uses `browse.releaseFeed`'s transport through a small `fetchAlbums` added in `LikedReleases.kt` (takes the `ReleaseFeedTransport` as a parameter, so `ReleaseFeedService.kt` is not touched). |
| `screens/foryou/NewReleasesScreen.kt` | `ReleaseRow`'s `RecFeedbackButtons(..., onAccept = { adder.liked(item.entry) })` (only when `releaseId != null`). Add a `likedSection(...)` LazyColumn block above Out now. The empty state is gated on feed + liked. Add a `LaunchedEffect(Unit) { adder.hydrateMissing(...); adder.sweep(now) }` and the "Pre-added" label. Add `NewReleasesPresentation.likedRowStatus(state, message)` copy (pure). |
| Launch/foreground sweep | `NewReleasesScreen` `LaunchedEffect` plus `ForYouTilesScreen` appearance. Wiring an app-level lifecycle hook waits until the parity branch lands. |

Android today has no album preview screen, so its row tap keeps opening Apple Music. The Liked row's
Add button is how Android adds.

## 5. Tests

### 5.1 Pure logic (both platforms, same cases)

`LikedReleaseSelectionTests` (iOS `apple/Tests/Unit/LikedReleaseSelectionTests.swift`; Android
`app/src/test/.../data/recs/LikedReleaseSelectionTest.kt`):
- accepted `rel:` + meta + not owned → row. `relartist:` → skipped. A missing meta id goes to `needsHydration`.
- owned via the probe → dropped. Owned via `ownsVersion` → dropped. Owned but the write is unproven and the device can write → kept as a retry row.
- liked 200 days ago, out of the window → still a row (no age limit).
- cleared or rejected verdict → not a row (and pruned from the store).
- `added` within 24 h → hidden. After 24 h and still not owned → shown again.
- `awaitingRelease` with a proven write before release → hidden from Liked (it's in Coming soon). At `releaseAt + 3d` and not owned → shown.
- ordering: in-flight/errors first, then by `acceptedAtMs` desc.

`NewReleaseLikeAdderTests` / `NewReleaseLikeAdderTest.kt`, with a fake `ReleaseAddPort` that counts calls:
- 👍 that landed accepted → exactly one `add`. A lit-👍 tap (undo) → zero adds. A double tap while in flight → one add.
- report `recorded + confirmed` → state `added`. `recorded + failed` → `failed` with the `libraryWriteNotice` text, and the verdict is still accepted.
- nothing recorded while offline → `offline`. `sweep` retries it once and respects the 6 h throttle. A `failed` item is **not** auto-retried.
- pre-order (`releaseAt` in the future) with a proven write and nothing recorded → `awaitingRelease`. `sweep` before release does nothing, `sweep` after release calls `add`.
- `addAll` runs sequentially (the fake asserts it is never re-entered) and skips in-flight and owned items.
- `unliked` before a queued add starts → no add. During an add → the add completes and nothing is removed from the library (the fake has no remove, so the test asserts no other port call).
- `adding` persisted then reloaded → becomes `offline`.
- `state(for:releaseAtMs:nowMs:)` covers every row of the table in 1.3.

`RipsStore` (iOS `apple/Tests/Unit/`): `addRelease` returns `recorded == false` plus the
"Couldn't read the album's tracks" error when the expansion is empty, and `discoverError` is still
set for the album page (regression check on the shared body).

Hydration decode: an `AlbumsCatalogResponse` fixture covering a full date, a bare year → nil,
`isSingle` → "single", a missing `relationships`, and an id Apple didn't return → tombstoned.

`LikedReleasesStore`: a round-trip, a malformed row skipped, unknown keys ignored.

### 5.2 UI test ids

| id | element |
|---|---|
| `new-liked-section` | the "Liked — not added" header |
| `new-liked-add-all` | Add all (n) |
| `new-liked-row-<storeId>` | the row (iOS: pushes the album preview) |
| `new-liked-add-<storeId>` | Add / Retry button (label carries the state; `accessibilityValue` = state raw) |
| `new-liked-status-<storeId>` | the state line ("Adding…", error text, "Will add when you're back online") |
| `new-release-preadded-<storeId>` | the "Pre-added" badge on a Coming soon row |
| `rec-accept-rel:<id>` | existing 👍 (unchanged) |

iOS UI tests (`apple/Tests/UI/ForYouTilesUITests.swift`, fixture mode `PDJ_REC_FIXTURE=1` +
`PDJ_USE_FIXTURE`):
1. Open New → `new-liked-section` and `new-liked-row-9000000004` exist (the seeded resurfaced like).
2. Tap `new-liked-add-9000000004` → the row disappears (the fixture port injects the provisional album, so ownership flips).
3. Tap `rec-accept-rel:9000000001` → the row leaves Out now and then leaves the screen (it was added). It must **not** reappear in Liked.

Android Compose UI tests (`app/src/androidTest/.../screens/`) use the same tags as `testTag`s.
They're optional this pass if the parity branch owns androidTest infra. The pure tests are required.

## 6. Non-goals / follow-ups

- No silent retroactive bulk add (Levi's wording). Add all is explicit.
- No change to the New tile count or CarPlay.
- Liking a *song* elsewhere in For You is unchanged (collection tiles already add on 👍).
- Follow-up: a "· n liked" sub-line on the tile. An Android album preview screen for parity
  with iOS's "Add remaining (n)" ticks.
