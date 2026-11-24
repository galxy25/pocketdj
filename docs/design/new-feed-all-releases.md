# For You ▸ New: keep every release in the window

**Status:** implemented (fix/new-feed-all-releases)
**Follows:** `docs/design/foryou-new-kind-filter.md` §9 ("One release per artist"), merged in c61d7e1c.
**Goal:** the feed holds every release each artist has inside the window (out now, the last 30
days, plus everything coming soon), so the albums/singles filter never loses a record. Then the
stopgap footer caveat ("A newer single can hide an artist's album.") is removed.

## 0. The bug, measured

`ReleaseFeedService` (iOS `apple/PocketDJ/Services/Recommendations/ReleaseFeedService.swift`,
Android `android/.../data/recs/ReleaseFeedService.kt`) stores `[artistId: ArtistReleaseEntry]`, and
each entry is the artist's `views=latest-release`, which is one record. An album followed a week
later by a single is overwritten by the single. Under "Albums only" (US1, Levi's mode) the album
is gone.

How common this is. A live probe on 2026-11-23 covered 400 artists: the similar-artist
neighbourhood of 16 popular seeds, using the developer token minted from the MusicKit .p8 and
catalog reads only.

| | |
|---|---|
| Artists with ≥1 release in the window | 81 of 350 measured |
| …with **≥2** releases in the window | **32 (≈40%)** |
| In-window releases, total | 175. Kinds: 122 single, 46 album, 7 compilation. 5 were pre-orders. |
| Most releases one artist had in the window | 9 |

So for about 40% of the artists who have anything new, today's feed shows one record and drops
the rest.

## 1. API: what the code calls today, and what it will call

### Today
```
GET /v1/catalog/us/artists?ids=<≤50>&views=latest-release,similar-artists
```
One request per 50 due artists, two in flight, a 2 s debounce, 5 attempts with jittered backoff,
retries on 429/5xx/IO only. Measured on 50 artists: **1.1–1.2 MB, 1.4–1.9 s**. Most of the bytes
are the `similar-artists` view, which carries full artist attributes and editorial notes for 10
neighbours per artist.

### Options probed (all on 50-id batches, `us` storefront)

| Shape | Result |
|---|---|
| `views=…,full-albums,singles` | Rejected. The views don't partition: a "… - Single" (`isSingle: true`) shows up in `full-albums`. Live albums are a separate view (Radiohead's latest release, *Hail to the Thief (Live Recordings)*, is in neither). Each view is capped at 10 items and wants `limit[<view>]=N` (`limit[views]` is ignored). |
| `/v1/catalog/us/artists/{id}/albums?sort=-releaseDate` | Works, newest first, every kind. But it's **one request per artist**, 50× today's count. Kept only for the rare overflow page (§1.3). |
| `include=albums` (relationship) in the batch, unsorted | Catalog order (*OK Computer* first). Useless. A plain `sort=-releaseDate` is ignored. |
| **`include=albums&sort[albums]=-releaseDate&limit[albums]=N`** in the batch | **Works.** Each artist's albums relationship comes back newest first, all kinds (albums, singles, EPs, live, compilations, pre-orders, appears-on), in the same single batched request. `limit[albums]` max is 100 (101 → HTTP 400). Percent-encoded brackets (`%5B`/`%5D`) work. |
| …the above **plus** today's `views=latest-release,similar-artists` | **HTTP 504 Gateway Timeout** on 2/8, 4/8 and 1/8 batches in three runs, even with sparse fieldsets. Latency was 3–5 s against what looks like a ~5 s gateway budget. Not shippable. |
| `include=albums&sort[albums]=-releaseDate&limit[albums]=25&fields[albums]=…&fields[artists]=name` (**chosen**) | **570–630 KB, 0.8–0.9 s**, 100% HTTP 200 over 11+ batches. At `limit=10`: 250 KB, 0.6–0.7 s. |

Correctness of the chosen shape, from the same 400-artist sample:
- The sort is strictly monotone: 0 of 400 artists out of order among full dates. A bare year
  (`"2016"`) can sit among them, and it parses to nil as it does today.
- Every in-window `latest-release` answer was also in the sorted relationship: 0 misses across
  ~350 artists, pre-orders included. The relationship is a superset of what the feed reads today.
- No artist filled all 25 slots with in-window releases. The maximum was 9.

### 1.1 The new request
```
GET /v1/catalog/us/artists
    ?ids=<≤50 comma-separated>
    &include=albums
    &limit[albums]=25
    &sort[albums]=-releaseDate
    &fields[artists]=name
    &fields[albums]=name,releaseDate,artwork,trackCount,contentRating,isSingle,isCompilation,artistName
```
- Same endpoint, same batch size (50), same concurrency (2), same debounce, backoff, retry
  classes, single-flight drain, failed-batch re-queue, and success-stamps-silent-artists rule.
  **Nothing in the drain changes except the URL and the parser.**
- `artistName` (the release's credit) is new. It is used for the appears-on filter (§3.1) and the
  cross-artist dedupe (§3.2).
- **`views=latest-release` is dropped.** The sorted relationship subsumes it (measured above).
- **`views=similar-artists` is dropped from this request.** Grep shows **no production consumer**:
  `similarArtistIds(for:)` is called only by tests, on both platforms. Keeping it is what causes
  the 504s. The cached `similarArtistIds` / `similarCheckedAtMs` stay in the document and keep
  being carried forward by the existing "a sparse answer never erases good data" rule, so nothing
  is lost. If something ever starts consuming similarity, it gets its own slow-cadence batch
  (`views=similar-artists`, keyed on `similarTTLDays`), not a ride on the release request.
  *Flag to Levi in the PR description; it is a deliberate scope call.*
- The decoder still reads `views.latest-release` / `views.similar-artists` when they are present
  (fixtures, tests, old captured bodies). It reads the union, deduped by id. Parsing is lenient as
  before.

### 1.2 Request budget

| | Today | After |
|---|---|---|
| Requests per drain | ⌈due/50⌉ | ⌈due/50⌉ (**unchanged**) |
| One-shot seed (~493 artists) | 10 | 10 |
| Bytes per 50-id request | 1.1–1.2 MB | ~0.6 MB |
| Latency per request | 1.4–1.9 s | 0.8–0.9 s |
| Extra requests | 0 | an overflow page per *saturated* artist (§1.3): 0 measured in 400 |

Cost per artist goes down, not up. That's because the release list is cheaper than the
similar-artists payload it replaces.

### 1.3 Overflow (the one new request kind)
An artist is **saturated** when it returned exactly `limit` (25) items, the **oldest** of them is
still inside the window, and the relationship has a `next`. A flood of remix singles is the
realistic way to get there. For each saturated artist in a successful batch, the drain fetches
one follow-up:
```
GET /v1/catalog/us/artists/{id}/albums?sort=-releaseDate&offset=25&limit=100&fields[albums]=<same>
```
(`next` hrefs omit `sort` and `fields`, so the URL is built, never followed verbatim.)
- It runs inside the same drain, through the same transport, under the **same 2-permit
  semaphore**, with the same backoff. iOS gets this from its task group; Android from its
  `Semaphore`. The batch's outcome is not complete until its follow-ups finish.
- A failed follow-up does **not** fail the batch. The artist keeps the 25 it got, is stamped, and
  `truncated` is logged. Losing release 26+ for one check is better than re-queuing 50 artists.
- At most one follow-up per artist per check. 125 releases in 30 days is beyond any real artist.

## 2. Data shape and migration

### 2.1 In memory
```swift
// iOS
private(set) var entries: [Int: [ArtistReleaseEntry]]   // artistId → rows, NEWEST FIRST
```
```kotlin
// Android
private val entries = HashMap<Int, List<ArtistReleaseEntry>>()   // same invariant
```
`ArtistReleaseEntry` stays **the row type**, one release per row. Every downstream consumer
already takes one (`ReleaseFeedItem.entry`, `LikedRelease(entry:)`, `NewReleaseLikeAdder.liked`,
`kindClass`, the fixtures), so none of them change shape.

Invariants (enforced in one place, `ReleaseFeedCache.normalize(rows:nowMs:)`, pure, both
platforms):
1. Rows are sorted by `releaseAtMs` descending, with undated rows last. `rows[0]` is the
   **head**: the newest release, which is exactly what v1 stored.
2. No two rows share a `releaseId`.
3. Artist-level fields (`artistName`, `checkedAtMs`, `similarArtistIds`, `similarCheckedAtMs`)
   are **identical on every row** of the artist. Stamping a clock rewrites all rows; there are
   only a handful.
4. Eviction: keep the head always. Keep every other row only if it is future-dated or
   `releaseAtMs ≥ now − (windowDays + 1) days`. Rows without a date are dropped unless they are
   the head. Cap at 1 + 125 rows.
5. An artist with no releases is one bare row with `releaseId == nil`. That's exactly today's
   "checked, nothing" row.

New optional field on `ArtistReleaseEntry`: `releaseArtistName: String?` (Apple's credit for the
release). It's additive, nil on old rows, and Android serializes it with `explicitNulls = false`.

### 2.2 On disk: same shape, `schemaVersion: 2`
```json
{ "schemaVersion": 2,
  "entries": [ {artist A, head}, {artist A, older}, {artist B, head}, … ],
  "seededAtMs": … }
```
The file keeps its name (`pocketdj-release-feed.json`) and its structure. `entries` simply becomes
**one row per release** instead of one per artist, written grouped by artist, head first.

- **Upgrade (v1 → v2):** a v1 file is a valid v2 file in which every artist has ≤1 row. `load()`
  groups rows by `artistId` (stable order), then runs `normalize`. **No refetch.** TTL clocks are
  preserved, so each artist gains its full list on its next *normal* TTL-due play (≤14 days, sooner
  for heavy artists), or immediately via ⋯ → "Check for new releases" (`recheckKnownArtists`,
  unchanged). This is the "lazy re-ask on the normal TTL"; there is no forced storm and no
  migration flag.
- **Downgrade (v2 file read by an old build):** iOS `load()` builds its dict with
  `uniquingKeysWith: { a, _ in a }` and Android uses `putIfAbsent`. **Both keep the first row per
  artist**, which is the head, which is precisely v1's meaning. Old builds ignore `schemaVersion`
  (decoded, never checked), and Android ignores the unknown `releaseArtistName` key
  (`ignoreUnknownKeys`). iOS's synthesized `Decodable` ignores unknown keys. Downgrade is lossless
  for what the old build can show.
- Cross-platform decode (`documentRoundTripsAndDecodesIosShape`,
  `encodedEntryAlwaysCarriesNameAndCheckedAtForIosDecoder`): unchanged contract. Every row still
  always encodes `artistName` and `checkedAtMs`.
- The file grows by about one row per in-window release: a few hundred rows, tens of KB.

### 2.3 Synced shapes: none change
- Feedback ids: `rel:<albumStoreId>` for every row (unchanged, now one per release), and
  `relartist:<artistId>` for the bare row. `feed()` already drops rows without a `releaseId`, so
  `relartist:` still never reaches a feed row. It lives on only in existing feedback records.
- `LikedRelease` / `LikedReleasesStore` (built from an `ArtistReleaseEntry` by store id): unchanged.
- `RecFeedbackStore`, settings (`newReleaseKindFilter`), and the For You snapshot: untouched.

## 3. Dedupe (pure: `ReleaseFeedDedupe`, both platforms)

The relationship returns things latest-release never did. The probe found all of the following,
and each gets a rule. **Order matters**, and it runs at **apply** time (1–2) and **read** time (3).

### 3.1 Appears-on (apply time)
The albums relationship includes records the artist is only *featured* on. In the sample, 31 of
175 in-window rows (18%) were things like Drake on Future's "Ya Hit (feat. Drake, …) - Single".
latest-release was the artist's own record.
**Rule:** keep a release only if the artist is in its credit:
`RecVersionIdentity.creditArtistKeys(release.artistName)` contains
`RecVersionIdentity.artistKey(artist.name)`. A release with an empty `artistName` is kept, since
it fails open. Featured appearances still show up when he plays the credited artist.

### 3.2 Same id (apply + read)
- Apply: the relationship can repeat an id (Drake: `6831506152` three times). Dedupe by
  `releaseId` within the artist.
- Read: the same `releaseId` can sit under two artists (a duet credited "A & B", both played).
  `feed()` keeps **one** row per `releaseId`. It prefers the artist whose key is *first* in the
  release's credit, then the lower `artistId`. This is what makes `ReleaseFeedItem.id` unique
  (§4.1), and it is **required**: SwiftUI `ForEach` and Compose `LazyColumn` keys must be unique.

### 3.3 Editions and clean/explicit twins (read time, after the window filter)
Group the artist's in-window rows by **(artist, kind bucket, base title)**:
- kind bucket = `NewReleaseKinds.classify(...).isAlbumBucket`;
- base title = `RecVersionIdentity.parse(title stripped of " - Single" / " - EP").base`.

Collapse a group only when **every** member's `parse(...).klass` is `.standard` or `.cosmetic`.
Never collapse `.derivative` (a named remix is its own single) or `.distinct` (a live record is new
music).

That catches both cases the probe found:
- **Clean/explicit twins.** 20+ pairs in 400 artists: same title, different ids and UPCs, release
  dates up to **6 days apart** (Saweetie *Details*: explicit 11-13, clean 11-19). Same signature,
  `explicit` differs.
- **Cosmetic editions inside one window** (album + its Deluxe two weeks later). Outside one window
  they never meet, and the existing `ownsReleaseVersion` probe already hides a Deluxe of something
  he owns.

The representative row of a collapsed group is chosen by:
1. **the member he already has a verdict on** (👍 or 👎 in the `new` scope), via the injected
   `hasVerdict: ((String) -> Bool)?`, so a verdict given to whichever twin latest-release happened
   to return keeps applying;
2. **content rating** per `SettingsStore.preferExplicitVersions` (true → explicit; false/unset →
   clean, matching the setting's documented default for new picks), via an injected
   `prefersExplicit: (() -> Bool)?`. Android has the same mirror in `PlaybackGraph`
   (`preferExplicitMirror`); wire that one;
3. newest `releaseAtMs`;
4. lowest store id (deterministic).

Ownership is decided **per group**: if `ownsRelease` / `ownsReleaseVersion` is true for **any**
member, the whole group drops. Owning the clean twin is owning the record.
`ReleaseFeedItem` gains `alternateReleaseIds: [String]` (the collapsed members). It's used for the
ownership check, for tests, and for nothing else in the UI.

### 3.4 Not collapsed: a single and the album it's on
"anything" (8 tracks) and "anything - Single" (1 track), same day, Phoebe Bridgers. These are
**different kind buckets**, so the rule above never groups them. **That's intended:** Albums only
must show the album and Singles only must show the single, which is the whole point of the
filter. In Everything / Albums-then-singles both rows show, as two records. Downstream already
copes:
- ▶/🔀 collapse duplicate tracks. `ReleaseStreaming.items` dedupes by resolved song id; its doc
  comment already names this case.
- Once he owns the album, `ownsReleaseVersion` (one artist's songs **and** albums, feature 6)
  suppresses "Song - Single" as a different version of a song he owns, so the singles drop out
  with no new code.
- A non-title-track single ("Track 3 - Single" released before the album) can't be matched to
  the album without track listings. Fetching those would mean a per-release request, which the
  feed deliberately never makes. It's accepted, and the row is still a real release.

## 4. Everything downstream that assumed one entry per artist

| # | Where | Assumption | Change |
|---|---|---|---|
| 1 | iOS `ReleaseFeedItem.id` (`Int` = `entry.artistId`, `Identifiable`) | one row per artist | `id: String` = `feedbackId` (`rel:<releaseId>`), unique by §3.2. `NewReleasesView.section` `ForEach(a.flat)` works unchanged. |
| 2 | Android `ReleaseFeedItem.id: Int` + `NewReleasesScreen` `LazyColumn` keys `"${status.raw}-${artistId}"` (lines ~469/473/477) | one row per artist | **This would crash** (`IllegalArgumentException: Key … was already used`). Keys become `"${status.raw}-${item.feedbackId}"`, and `id: String = feedbackId`. |
| 3 | Row ids: iOS `new-release-\(artistId)` / `new-release-kind-\(artistId)` (`ForYouDetailViews.swift` ~478/526), Android `testTag("new-release-${artistId}")` / `new-release-kind-…` (~642/667) | unique per artist | `new-release-<releaseId>` / `new-release-kind-<releaseId>`. Update `ForYouNewKindUITests.row(_:_:)` to take a release id (fixture ids `9000000001…`). `new-release-preadded-<releaseId>` is already per release. |
| 4 | `ReleaseFeedService` iOS: `entries` dict, `load`, `save`, `apply`, `seedForTesting` (uniquing), `similarArtistIds(for:)`, `needsSeed`/`entries.isEmpty`, `emptyReason`, `canRecheck`, `recheckKnownArtists` (name from the entry), `noteArtistPlayed` (`entries[id]?.checkedAtMs`), `seedFromRecentListening` (`entries[a.id] == nil`) | dict of one | `[Int: [ArtistReleaseEntry]]`. The head (`rows.first`) answers every artist-level read: TTL, name, similar. `isEmpty` semantics are unchanged (artists, not rows). `seedForTesting(_:)` **groups** instead of uniquing, so a test or fixture can seed two releases for one artist. |
| 5 | Android service: same list + `entry(artistId)` (public, used by tests only), `cachedArtistCount` | dict of one | `entry(artistId)` returns the head. Add `releases(artistId): List<ArtistReleaseEntry>`. `cachedArtistCount` counts artists. |
| 6 | `apply(outcome:)`, both platforms | replace one entry | Replace the artist's **whole row list** with the fetched list (authoritative: a withdrawn or re-id'd pre-order disappears), after §3.1–3.2 and `normalize`. Carry similar fields forward from the old head. Silent artists still get one bare stamped row (or their existing rows restamped). Failed batch: unchanged, nothing stamped, ids re-queued. |
| 7 | `ArtistsCatalogResponse.entries(checkedAtMs:)` (iOS) / `ArtistsCatalogResponse.parse` (Android) | `latestRelease.data.first` | Return **all** rows: the union of `relationships.albums.data` + `views.latest-release.data`, deduped by id, with kind mapping unchanged (`isSingle` → single, `isCompilation` → compilation, else album) and `releaseArtistName` from `attributes.artistName`. Also expose per-artist `truncated` (§1.3) and `next`. The "`data` missing ⇒ failure" guard is unchanged. |
| 8 | `feed()` / `outNow()` / `comingSoon()` / `newReleases()` | — | Flatten all rows → window filter → §3.2 cross-artist id dedupe → §3.3 group/collapse → ownership per group → sort. Still pure, no network, render-path safe. Cost: ownership/version probes are O(1) memoized per row, and rows ≈ 2× today. |
| 9 | New tile count (`ForYouGrid.tiles` iOS; `KindFilteredForYouSource` / `ReleaseFeedForYouSource` Android) | — | No code change. Counts rise to the true number of releases (expected; it's the fix). |
| 10 | CarPlay `CarPlayForYou.newReleaseItems` / `forYouRows` (rows keyed `releaseRowPrefix + releaseId`) | — | No code change; already per release. More rows, and CPListTemplate truncates at the system maximum as it does for every tile. Android Auto has no New list. |
| 11 | ▶/🔀 (`ReleaseStreaming.tracks(forReleaseIds:)`, cap `maxReleases = 25`) | — | No code change. The cap now bites more often: newest first, or albums first in `.albumsFirst`, per the existing comment. Track dedupe covers single/album overlap. |
| 12 | 👍 auto-add (`NewReleaseLikeAdder.liked(entry)`, `LikedReleases`), Liked — not added | — | No change. Keyed by store id. |
| 13 | `NewReleaseKinds.footerCaveat` + its call sites | the bug | **Delete** the function (iOS `NewReleaseKind.swift:157-161`, Android `NewReleaseKind.kt:132-133`), the `caveat:` parameter and `new-kind-hidden-caveat` row (iOS `ForYouDetailViews.swift` ~96/204-213, Android `NewReleasesScreen.kt` ~398-403), and the two `…FooterCaveat` unit tests. Update the `foryou-new-kind-filter.md` §9 bullet to point here. |
| 14 | `AppModel.swift:175`, `RecVersionIdentity.swift:165` doc comments ("`ArtistReleaseEntry.artistName` is Apple's canonical name for one artist id") | — | Still true. No change. |
| 15 | Android `AppleMusicApi.kt:101` / `AppleMusicApiModels.kt:247` (a separate `artists?views=latest-release,similar-artists` wrapper) | — | **Not touched.** It isn't the feed's path, and it belongs to the parity program. |
| 16 | Doc comments that say "ONE endpoint, ONE request shape … latest-release" (iOS service header lines 15-19, `ReleaseFeedModels.swift:208-213`; Android service KDoc line 73, models 203-207) | — | Rewrite to §1.1 with the measured numbers and the 504 reason similar-artists left. |

## 5. Fixtures

- Default UI fixture (`uiFixtureEntries`): **unchanged**, three artists, three releases, so the
  CarPlay, toolbar and streaming counts don't move.
- `PDJ_NEW_FIXTURE_KINDS=1`: unchanged (900005, 900006).
- **New** `PDJ_NEW_FIXTURE_MULTI=1` (iOS, gated on `wantsUIFixture` like the others):
  `uiFixtureMultiEntries` adds a second release for **900_001 "The Test Pressing"**:
  `9000000007` "Second Side (Edit) - Single", kind single, 1 track, out now **0.5 d** (newer than
  its album at 2 d). That's exactly the US1 story. Seeded through `seedForTesting`, which now
  groups.

## 6. Tests

### Unit (same cases both platforms; iOS `ReleaseFeedTests` + new `ReleaseFeedDedupeTests`; Android `ReleaseFeedServiceTest`, `ReleaseFeedModelsTest`, new `ReleaseFeedDedupeTest`)
- **The bug:** an artist whose response holds an album (10 d) and a newer single (2 d) yields
  **two** feed rows. `arrange(.albums)` keeps the album, and the footer's hidden count is 1 single.
  This is the regression test for US1.
- **Request shape:** the URL has `include=albums`, `limit[albums]=25`, `sort[albums]=-releaseDate`,
  `fields[artists]=name`, and the albums fields list. It has no `views=`. Batches stay ≤50, and the
  existing `testBatchSizeAndConcurrencyStayWithinMeasuredLimits` is unchanged. Replace
  `requestShapeBatchesOfFiftyWithBothViews` / `requestUrlFormat` / the iOS URL assertion
  (`ReleaseFeedTests.swift:374`) accordingly.
- **Parse:** a relationship body (captured from the probe: Taylor Swift, Radiohead, Drake slices
  with a repeated id) flattens into N rows, newest first, deduped by id, with
  `releaseArtistName` set. A legacy `views.latest-release` body still parses (union). A
  `data`-less body is still a failure.
- **Appears-on:** Drake's row for Future's "Ya Hit (feat. Drake…)" is dropped, a "A & B" credit
  is kept for A, and an empty credit is kept.
- **Cross-artist dedupe:** one release under two played artists gives one row, the first-credited
  artist wins, and the ids are unique.
- **Twins:** clean + explicit 6 days apart give one row. `prefersExplicit` true picks explicit,
  false/unset picks clean. A verdict on the other twin wins over preference. Owning *either* twin
  drops the group.
- **Editions:** album + "(Deluxe Edition)" in one window give one row, the newer. Album + "(Live)"
  gives two rows (`.distinct`). "Song (X Remix) - Single" + "Song - Single" gives two
  (`.derivative`).
- **Not collapsed:** "anything" album + "anything - Single" give two rows, in different buckets.
- **Window/eviction:** after `normalize`, rows older than 31 d are gone except the head, future
  rows are kept, undated non-head rows are dropped, and the head is always present.
- **Migration:** a v1 document (one row per artist, `schemaVersion` 1) loads. Every artist keeps
  its row and `checkedAtMs`, `needsSeed` stays false, and **nothing is enqueued** by load or by a
  play inside the TTL. A v2 document round-trips. **Downgrade simulation:** decode a v2 file with
  the old rule (first row per `artistId`) and assert it's the head.
- **Apply replaces the list:** a refetch without a previously cached pre-order drops it.
  Similar fields carry forward onto the new head. A silent artist is restamped. A failed batch
  stamps nothing (the existing tests stay green).
- **Overflow:** a 25-item all-in-window response with `next` triggers exactly one follow-up URL
  (`/artists/{id}/albums?sort=-releaseDate&offset=25&limit=100…`). The follow-up runs under the
  2-permit cap (extend the existing fan-out counter test). A failed follow-up keeps the 25 and
  doesn't re-queue.
- **Ids:** `ReleaseFeedItem.id == feedbackId`. Update `NewReleasesPresentationTest` (lines 29/35)
  and `ReleaseFeedServiceTest` (403-405) expectations from artist ints to `rel:` strings.
- **Caveat removed:** delete `testAlbumsOnlyFooterCaveat` / `albumsOnlyFooterCaveat`.

### UI (iOS `ForYouNewKindUITests`)
- Re-key `row(_:_:)` to release ids. The existing three story tests otherwise pass unchanged; the
  footer counts don't move without the MULTI fixture.
- **New `testAlbumsOnlyKeepsAnAlbumBehindANewerSingle`** (`PDJ_NEW_FIXTURE_MULTI=1`): under
  Everything, `new-release-9000000007` sits above `new-release-9000000001` (date order, same
  artist). Pick Albums only: `new-release-9000000001` **exists**, `…7` doesn't, the footer value is
  2 (900002 and 9000000007), and `new-kind-hidden-caveat` doesn't exist.

## 7. Out of scope / follow-ups
- Similar-artists refresh on its own slow cadence, if a consumer ever ships (§1.1).
- Track-level single↔album matching (§3.4).
- The Android `AppleMusicApi` wrapper's own `views=latest-release` call (§4 #15).
