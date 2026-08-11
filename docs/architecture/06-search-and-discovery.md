# Chapter 6 — Search & Discovery: finding the right record fast

> Part of the [PocketDJ Architecture Book](../ARCHITECTURE.md). Prereqs:
> [Ch. 1 Foundations](./01-foundations.md), [Ch. 3 Catalog & Data Model](./03-catalog-and-data-model.md).
> This pillar serves **"instantly create… from diverse musical sources"** — you can't
> build a set from 100k tracks without fast lookup over the whole catalog.

---

## 1. Two modes, one search box

**Why.** Offline-first means the default must work with no network — but the loaded
device set is a subset (vinyl by default; Apple Music is opt-in and huge). To search
the **entire indexed catalog** across lyrics and sentiment, with **no server to run
and $0 when idle**, there's an opt-in online mode backed by OpenSearch Serverless.

```
 search box
   ├─ OFFLINE (default)   filter the LOADED set by title/artist locally (instant, no net)
   └─ ONLINE  (⚡, opt-in) query the WHOLE catalog across title/artist/album/lyrics/sentiment
                          via OpenSearch Serverless (aoss), signed with a read-only key
```

**Reading the diagram.** **Offline** filters only what's already in IndexedDB by
title/artist — fast, private, zero-network, but scoped to the loaded sources.
**Online** (a ⚡ toggle that appears once the user pastes a read-only key into Settings)
queries the full corpus over five fields including lyrics and sentiment.

---

## 2. OpenSearch Serverless (aoss)

**Source of truth:** the `es-search-index` skill (builder) + `src/search/esClient.ts`
/ `src/search/sigv4.ts` (web client) + `SearchService.swift` / `SigV4.swift` (native).

- **Collection** `pocketdj-search` (id `mii9dwge3uiee2tvivt5`, type SEARCH, **NextGen**
  in collection group `pocketdj-search-grp` with min-OCU **0**, standby ENABLED →
  **truly scales to $0 when idle**: ~10 min idle → 0 OCU, ~16 s cold-start on the first
  query after idle). Rebuilt 2026-07-02 from the classic 1.0-OCU-floor collection.
- **Index** `pocketdj`, endpoint `https://mii9dwge3uiee2tvivt5.aoss.us-west-2.on.aws`,
  SigV4 **service `aoss`**. The host is **published in `public/search-config.json`** and
  read at launch by both clients (native `SearchConfig` actor + PWA `loadSearchConfig`),
  so a collection swap changes the host **without a client rebuild**.
- **Builder** `node scripts/es-index.mjs … --profile levi`: `DELETE /pocketdj` →
  `PUT` mapping → `POST /pocketdj/_bulk` (1,500-doc batches) → `_refresh`. **Full reset
  each run** (corpus small → ~40s); `_id = item id` so re-runs upsert. The mapping adds a
  **`genreCategory`** keyword (`normalizer: lc`) alongside the raw `genre` — the
  **collapsed tier-1 category** (`genreCategory()` maps each album's ~600 raw genres into
  ~15 categories), so an online genre filter/sort matches the app's category options
  exactly (§6).
- **Read user** `djpocketsearch` — read-only IAM (`aoss:ReadDocument`, `DescribeIndex`);
  verified it **cannot write** (DELETE → 403). The user pastes its key/secret into
  Settings ▸ Online search.

---

## 3. Why a CloudFront proxy (the CORS trick)

```
   Browser (no CORS to aoss)                      Native app (no proxy needed)
        │ build query                                  │
        │ SigV4 sign for HOST=…aoss…amazonaws.com      │ SigV4 sign (same)
        ▼                                              ▼
   fetch SAME-ORIGIN  /pocketdj/_search          fetch DIRECT https://…aoss…/pocketdj/_search
        │  (signed for the aoss host)                  │
        ▼                                              ▼
   CloudFront behavior  /pocketdj/*  ── preserves Host ─▶  aoss origin
        │                                              │
        ▼                                              ▼
   { hits:{ total, hits:[{ _id, _source:{type,title,artist,album,bpm,key,camelot…} }] } }
        │  hitToItem(_source) — _id is authoritative
        ▼
   MusicItem[]  → existing grid renders
```

**Reading the diagram.** Both clients build the **same** query (next section) and
**SigV4-sign** it for `HOST = …aoss…amazonaws.com` with the djpocketsearch creds. The
split is *transport only*: the **browser** has no CORS to aoss, so it fetches a
**same-origin** path `/pocketdj/_search`; a **CloudFront behavior** matching
`/pocketdj/*` forwards it to the aoss origin **preserving Host**, so the signature
(signed for the aoss host) still validates. The **native app** has no CORS constraint
and fetches aoss **directly**. Both parse the standard OpenSearch response;
`hitToItem()` maps each `_source` to a partial `MusicItem`, treating **`_id` as
authoritative** for the id; the existing grid renders the results.

**Hard coupling:** the index name `pocketdj` **must equal** the proxy path prefix
`/pocketdj`, because the signed path the browser sends must be byte-identical to what
aoss receives behind CloudFront.

**NextGen update (2026-07-02).** After the scale-to-zero rebuild ([[aoss-scale-to-zero]]),
CloudFront can **no longer** forward straight to the aoss origin: the NextGen endpoint rejects
CloudFront's injected `x-amz-cf-id` header ("must be signed in SigV4"), and public Lambda Function
URLs are blocked in this account. So the **browser** path is now
`/pocketdj/*` → **API Gateway HTTP API `pocketdj-search`** → **Lambda `pocketdj-search-proxy`**
(`scripts/lambda/search-proxy/index.mjs`) which makes a CLEAN outbound request to aoss forwarding
ONLY the browser's SigV4 headers (`authorization`, `x-amz-date`, `x-amz-content-sha256`) — so aoss
sees exactly what the browser signed, and the djpocketsearch signature still does the auth (~$0.001/mo,
no idle cost). The **native app is unchanged** — it still fetches aoss directly (no CORS, no
`x-amz-cf-id`). Both clients read the aoss host from `public/search-config.json`.

---

## 4. The query + hit shape

```
 QUERY  POST /pocketdj/_search
   { from, size, track_total_hits:true,
     query:{ bool:{
       must:[ multi_match{ query, fields:["title^3","artist^2","album^1.5","lyrics","sentiment^2"],
                           type:"best_fields", fuzziness:"AUTO", operator:"and" } ]   // [] → match_all
       filter:[ term{type}? , <structured clause filters>… ],
       must_not:[ <neq / none-of clauses>… ] }},
     sort:[ {<docfield>:{order}}… , {id:"asc"} ] }   // SERVER sort + stable id tiebreaker

 HIT    { _id, _source: EsHitSource }    ·    hits.total.value = EXACT count
   EsHitSource { id,type,title?,artist?,album?,albumId?,genre?,year?,bpm?,key?,
                 camelot?,explicit?,sourceType?,source?,trackNumber? }
 SIGN   SigV4 service="aoss" · host;x-amz-content-sha256;x-amz-date(;…token)
```

**Reading the diagram.** The query is a `bool` with a boosted `multi_match` `must`
across title/artist/album/lyrics/sentiment (`AND`, fuzzy; an empty query degrades to
`match_all`) plus **structured filter clauses** translated from the Browser's filter model
into `filter`/`must_not` terms (so online honors the same filters as on-device — §6), and a
**`sort`** array (§4.1). A hit is `{_id, _source}`; `_source` is the flat `EsHitSource`.
Signing uses SigV4 service `aoss`, which is why the CloudFront proxy must preserve Host.

### 4.1 Pagination + server-side sort

**Why.** The offline filter **caps results at 60** — fine for a tight query, useless for
"every soul song." So online search **pages**: `from/size` offset windows that the
client **accumulates** as the user scrolls, with **`track_total_hits: true`** so aoss
returns the **exact** total (not the 10k-capped default) and the UI shows the real count and
knows when it's done. And because the client only ever holds the *loaded* pages, it **can't**
sort the whole result set locally — so the Browser's multi-key **sort is pushed to the
server**.

**Source of truth (native):**
[`apple/PocketDJ/Services/Search/SearchService.swift`](../../apple/PocketDJ/Services/Search/SearchService.swift)
(`search(from:size:)`, `sortBody`, `FilterQuery`),
[`apple/PocketDJ/State/OnlineSearchModel.swift`](../../apple/PocketDJ/State/OnlineSearchModel.swift)
(`loadMore`, `hasMore`, accumulation).

```
 OnlineSearchModel
   query/kind/filter/SORT change → reset(items=[], loadedCount=0, total=0) → page from=0
   user scrolls to bottom  → loadMore(): fetch from=loadedCount, size=pageSize(50), APPEND
   total = hits.total.value (exact, header "N of TOTAL")
   hasMore = loadedCount < total  ∧  loadedCount < maxResultWindow (10k aoss from+size cap)

 sortBody(sortKeys, hasQuery)   — SortKey field id → SORTABLE doc field
   text  name/artist/sentiment → ".kw" keyword subfield   (text fields aren't sortable)
   genre → genreCategory keyword (collapsed tier-1, §2)
   numeric year/bpm/length/trackNumber/trackCount → the field itself
   key/camelot/source/fileType/country → their keyword field
   … ALWAYS append {id:"asc"} LAST  → STABLE from/size paging (no dup/skip across pages)
```

**Reading the diagram.** `OnlineSearchModel` **resets** (clears the accumulator + offset)
on any change to query, kind, filters, **or sort** — anything that changes the full result
order must restart paging from `from=0` — then `loadMore()` fetches the next
`from=loadedCount` window and **appends**, tracking `loadedCount` separately from
`items.count` so de-duping can't desync the cursor. `hasMore` is false once the accumulator
reaches the exact `total` **or** hits OpenSearch's 10k `from+size` **`maxResultWindow`**
(offset pagination tops out there). **`sortBody`** maps each `SortKey` to a *sortable* doc
field — text fields can't sort on the analyzed field, so they target the **`.kw`** keyword
subfield; `genre` targets the precomputed **`genreCategory`** keyword (§2); numerics sort
directly — honoring `asc`/`desc`, and **always** ends with an `{id:"asc"}` tiebreaker so
equally-ranked rows page in a **stable** order (offset pagination never duplicates or skips a
row). An empty query with no explicit keys sorts by `id` alone; with a query, `_score`
relevance leads and the id tiebreaker stabilizes ties.

**How (worked example): "midnight".** The first page POSTs `{from:0, size:50,
track_total_hits:true, …, sort:[…,{id:"asc"}]}`; aoss returns `hits.total.value = 470` and
the first 50 hits. The model reports `total=470`, the header shows "50 of 470", and
`hasMore` is true. Scrolling fires `loadMore()` → `from=50` → appends the next 50 → "100 of
470" — same query, same fields, server-sorted, paging stably to the full 470 (or the 10k
window, whichever is smaller).

---

## 5. Discovery surfaces (the catalog side)

Search is the precise lookup; the **star map** is the spatial discovery lens. Both
read the same loaded catalog (Ch. 3) — grouping by **genre / BPM band / Camelot key**
is pure client-side derivation over `SongItem.genre`, `bpm`, and `camelot` (the
storybook §1–§4). No backend involvement; this is why discovery works fully offline.

The native app adds two *outward* discovery surfaces on top: **Discover** (§5.1),
which searches the whole Apple Music catalog and pulls songs/albums *into* the loaded
catalog, and the **"?♪?" ShazamKit recognizer** (§5.2), which turns the song playing
in the room back into a catalog row.

### 5.1 Browse ▸ Discover — search the whole Apple Music catalog, ＋ Add it

**Why.** Offline (§1) and online (§2–§4) search both cover what's already indexed.
Discover searches the **entire Apple Music catalog** and lets ＋ Add materialize a hit
— one song, or a whole album — as a first-class catalog citizen immediately.

**Source of truth:**
[`apple/PocketDJ/Views/BrowseDiscover.swift`](../../apple/PocketDJ/Views/BrowseDiscover.swift)
(`DiscoverSearchModel` / `DiscoverAlbumSearchModel` debounce+merge, `DiscoverAddWording`,
`DiscoverAlbumAddState`, the rows),
[`apple/PocketDJ/State/RipsStore.swift`](../../apple/PocketDJ/State/RipsStore.swift)
(`discoverSearch`/`discoverSearchAlbums`, `discoverAdd`/`discoverAddAlbum`, `fetchAlbumTracks`),
[`apple/PocketDJ/State/DiscoverAddsStore.swift`](../../apple/PocketDJ/State/DiscoverAddsStore.swift)
(provisional entries + the supersede `split`/`splitAlbums`), `scripts/rip-server.mjs`
(`GET /search`, `GET /album-tracks`).

```
 Browse "Show" tabs:  Albums · Songs · Artists · DISCOVER
   Discover rides BrowseState.searchMode == .discover (persisted) — NOT a 4th ItemKind,
   so the filter/sort machinery never sees it. Nested Songs|Albums scope (session-only)
   + "Refine by artist" (WIDENS the server term, NARROWS the hit list client-side).

 400 ms debounced query → TWO catalogs in parallel, merged, dedup by Apple Music store id:
   • MusicKit catalog search (when authorized) — full coverage + real ranking, LEADS
   • rip-server GET /search (entity=song|album — iTunes Search API proxy) — reachable by
     every tester (no subscription); its SONG rows win ties (the server manifest is the
     authority on ripped/url)

 ＋ Add (song)   → library write (if canAddToLibrary) + requestRip("amrec_<storeId>") + poll
                   → provisional DiscoverAddsStore entry → in the catalog NOW
 ＋ Add (album)  → library write · tracks via MusicKit, else GET /album-tracks?id=<collectionId>
                   → per-track amrec_ rip fan-out (ACCEPTED tracks only) → ONE batched
                     provisional album "amrec_album_<collectionId>" + its songs
                   row: ＋ → n/m spinner → ✓ Added  |  ⚠ n/m partial (settled with failures)

 help text: DiscoverAddWording.addHelp(noun:, canAddToLibrary:, opensInMusic:)
 supersede: a real indexed song/album with the same appleMusicId later REPLACES its twin
```

**Reading the diagram.** Discover is the fourth **Show** tab, but deliberately not a fourth
`ItemKind` — it rides `BrowseState.searchMode` so the on-device filter/sort pipeline stays
untouched; leaving the tab returns to device mode. Each keystroke (title field *or* artist
refine) re-arms a **400 ms** debounce, then **two sources** run in parallel and merge, deduped
by the Apple Music store id: **MusicKit** (full catalog coverage + real relevance — the iTunes
proxy misses whole tracks) leads when the account is authorized; the **rip-server `/search`
proxy** is reachable by every tester and, for songs, wins ties because the server manifest is
the authority on ripped/streamable state.

**＋ Add (song)** is two *independent* actions: save the song to the user's own Apple Music
library (when the device can write it) and ask the rip server to prepare the user's copy via
the standard `requestRip` path under the ad-hoc **`amrec_<storeId>`** id, following the job
with the same background poll single-song rips use. Once the server accepts (or already holds
the media), a **provisional `DiscoverAddsStore` entry** makes the song a catalog citizen
immediately — browsable, collectable, burnable. **＋ Add (album)** expands the album into
tracks (MusicKit when authorized, else the subscription-free `/album-tracks?id=<collectionId>`
proxy) and fans each track out as a per-song `amrec_` rip; only **accepted** tracks are
recorded (a per-track miss records nothing — no dead rows), and the provisional album + songs
land in **one batched inject** so the ~90k-row live catalog rebuilds once, not per track. The
row's trailing state is the pure, unit-tested `DiscoverAlbumAddState`: `adding (n/m)` →
`added`, or **`partial (n/m)`** once every track is *terminal* (ready or failed) — a single
track that never lands must not pin the spinner forever.

**Capability-aware wording (F7).** The ＋ button's help text comes from one pure helper —
`DiscoverAddWording.addHelp(noun:canAddToLibrary:opensInMusic:)` — shared by the song **and**
album rows so the wording can't drift or overstate. On iOS/iPadOS with an authorized
contributor it reads "Save this song/album to your Apple Music library and prepare your copy";
on macOS `canAddToLibrary` is false, so an **album** (which carries a catalog URL) says "Open
this album in Music and prepare your copy" (`add()` deep-links Music.app under exactly the
`opensInMusic` condition), while a **song** hit carries no deep link and honestly says just
"Prepare your copy."

**Provisional → real: the supersede.** The provisional entries fold into the catalog as a
**synthetic source appended after every real one** (`AppModel.withProvisionalSources`; merge
is first-wins, so a real twin shadows without deleting). When the nightly indexer later lands
the real song/album, `DiscoverAddsStore.split`/`splitAlbums` match provisional entries against
the index **by `appleMusicId`** (songs: the track storeId; albums: the iTunes `collectionId`),
exclude them, and return remap pairs — song supersedes remap collection references via
`onDiscoverSupersede`; album supersedes only prune the provisional row (collections reference
song ids, never album ids). The album half of this dedupe only works if the index carries
album-level `appleMusicId`s: `scripts/resolve-apple-music-catalog.mjs` captures each track's
`collectionId` alongside its `storeId` (legacy cache hits without one are re-resolved), and
`scripts/fold-album-catalogid.mjs` stamps each album's `appleMusicId` from its member tracks'
most-common `collectionId` as a fold over the existing index — which is what **activates** the
Discover-album dedupe for albums the user already owns.

### 5.2 The "?♪?" recognizer

The **ShazamKit** listen-and-identify button sits at the top of the Browser list on the
catalog tabs (Discover has its own refine row there instead): tap → mic listen → match →
resolve against the loaded catalog, with a **＋ add → rip/burn** path for songs not in the
crate. It is a client capability, documented with the other native-only sources in
[Ch. 7 §5.2](./07-distribution-and-clients.md#52-shazamkit--the--recognizer); a
not-in-crate ＋ add saves the song to the user's Apple Music library, then rips + burns the
user's copy to this device under the same ad-hoc `amrec_<storeId>` id convention as §5.1
(`AppleMusicRecognitionSection.add` → `BurnStore.startRipAndBurn`).

---

## 6. The native Browse filters — genre + collection membership

**Why.** Beyond text + sort, the native Browser carries a structured **filter** model
(AND-composed clauses) that reaches PWA parity with two additions this branch lands: a
**genre** filter and **collection-membership** filters. Both run **on-device** (over the
loaded catalog) and translate to OpenSearch clauses **online** (§4, `FilterQuery`), so the
same filter holds in either mode.

**Source of truth:**
[`apple/PocketDJ/Browse/BrowseModel.swift`](../../apple/PocketDJ/Browse/BrowseModel.swift)
(the `Field` registry + `FilterEngine` predicates),
[`apple/PocketDJ/Browse/BrowseState.swift`](../../apple/PocketDJ/Browse/BrowseState.swift)
(the membership state + `applyMembership`),
[`apple/PocketDJ/Views/FilterSheet.swift`](../../apple/PocketDJ/Views/FilterSheet.swift)
(the clause editor + per-clause remove); storybook §6.

```
 GENRE filter (on TOP-LEVEL CATEGORIES) — multi-select
   options come from Genre.category(rawGenre) — collapses ~600 raw genres → ~15 categories
   applies to BOTH album rows (album.genre → category) AND song rows
     (genre resolved from the owning album at baseItems() construction — IndexSong has none)
   ops:  .inList  "any of"  (in-list / SHOW)      ·   .notInList "none of" (not-in-list / HIDE)
   + GENRE is a SORTABLE key (Genre.order)

 MEMBERSHIP filter (SONG mode only) — pre-populated from the user's collections
   includeIds / excludeIds : Sets mixing playlist (pls_) AND pocket (pkt_) ids
     SHOW  keep ONLY songs in ANY selected collection ("in playlist" / "in pocket")
     HIDE  drop songs in ANY selected collection ("not in playlist" / "not in pocket")
     both active → intersection ; *Any flag → "every playlist + pocket"
   memberSongIds(ids): songIds(forPlaylist:/forPocket:) — placed albums expand to tracks
   applied LAST in results() (after query → clauses → sort)

 PER-CLAUSE REMOVE : each clause row has its own remove (trash + swipe) beside "Clear All"
```

**Reading the diagram.** The **genre** filter no longer filters on raw genre strings: its
options are the **top-level categories** (`Genre.category` collapses the catalog's ~600 raw
genres into ~15 — the same buckets the star map uses), and it applies to **both** kinds —
albums map their `genre` through `Genre.category`, and **songs** carry the category resolved
from their owning album at `baseItems()` construction (an `IndexSong` has no genre field of
its own, mirroring the PWA's derived `SongItem.genre`). It's **multi-select** with two ops —
**`.inList` "any of"** (in-list / SHOW) and the new **`.notInList` "none of"** (not-in-list /
HIDE) — and genre is also a **sort** key. The **membership** filter is **song-mode only** and
**pre-populated** from the user's own collections: `includeIds`/`excludeIds` are Sets that
**mix** playlist (`pls_`) and pocket (`pkt_`) ids; SHOW keeps only songs in **any** selected
collection, HIDE drops them, both-active is the intersection, and the `*Any` flags expand to
*every* collection. `memberSongIds` resolves each id via `songIds(forPlaylist:/forPocket:)`
(which already expand placed albums to their tracks), and membership is applied **last** in
the `results()` pipeline. Finally, every filter clause gains a **per-clause remove** (trash
button + swipe in `FilterSheet`, calling `BrowseState.removeClause(id:)`) alongside the
existing **Clear All**, so one stray clause can be dropped without resetting the whole filter.

### 6.1 The favorite filter — a second read-time layer

**Why it is not a clause.** The ♥ filter looks like a third filter clause, but its truth lives
in **another store** (`FavoritesStore`, [Ch. 3 §5](./03-catalog-and-data-model.md#5-favorites--the-per-profile--document))
whose contents change independently of `BrowseState`. Folding it into `resultsKey` would give
you one of two bugs and no third option: leave the ♥ set out of the key and the memo serves
**stale rows** the moment a heart changes; put it in and the key **churns on every tap**,
destroying the memo the ~90k-row path depends on (§7). So it takes the same shape membership
already has — a **read-time layer**, applied fresh on top of the cached sorted array.

```
 BrowseState.FavoriteFilter : String { any, only, exclude }    NOT Codable — must never
   favoriteFilter = .any (default)                            reach Snapshot / persistence
   favoriteActive = favoriteFilter != .any

 applyReadTimeFilters(items, collections, favorites)      ← shared by results() + visibleResults()
   1. membership (§6)      song mode ∧ any include/exclude selected
   2. applyFavorites       song mode ∧ favoriteActive ∧ store injected
        wantFavorited = (filter == .only)
        keep row ⇔ favorites.favoriteIds.contains(item.id) == wantFavorited     O(1) per row
        non-song rows pass through untouched

 activeFilterCount = complete clauses + (kind == .song ∧ favoriteActive ? 1 : 0)
 clearAllFilters() = clauses.removeAll() + favoriteFilter = .any    (membership NOT cleared —
                     it owns its own always-visible "Clear membership" button)
```

**Reading the diagram.** `FavoriteFilter` is a three-state enum held **transiently** and
deliberately **not `Codable`**, so nothing can quietly add it to the persisted `Snapshot`
later. `applyReadTimeFilters` is the shared tail of both `results()` (full pipeline) and
`visibleResults()` (the cheap re-read the render path calls) — membership first, favorites
second, order irrelevant since both are independent row predicates. The favorite predicate
reads `favoriteIds`, a **Set**, so it stays O(1) per row across ~90k songs; non-song rows pass
through, exactly like membership. `.exclude` keeps everything **not currently** favorited —
which includes songs never touched **and** explicit un-♥ tombstones, because "not favorited"
is a statement about the current state, not about history.

Two smaller consequences. `activeFilterCount` counts the favorite filter (kind-gated to song
mode, like the membership term) so the toolbar's filled/unfilled filter glyph stays honest for
a favorite-**only** filter, which adds no clause. And `clearAllFilters()` releases it: the
favorite filter has no escape hatch of its own beyond `.any`, so the one "reset everything"
control must own it or a user who reached for it would be left with rows still hidden.

`BrowseView` injects the store as an **optional** `@Environment(FavoritesStore.self)` — a host
that hasn't wired it (a preview) degrades to "no constraint" instead of trapping — and folds
`favoriteFilter.rawValue` into `pagingKey`, so changing the constraint restarts paging at the
top. `pagingKey` tracks the **constraint**, not the store's contents: hearting a song
re-filters (the `@Observable` read in `visibleResults` invalidates the body) without collapsing
the scroll position — the same bargain membership already makes.

## 7. On-device Browse paging + results memo (large catalogs)

**Why.** The merged on-device catalog is large — a real device carries **~12.7k albums /
~105k songs** (My Vinyl + Apple Music (Local)). The native Browser used to rebuild the
whole `[BrowseItem]` array, re-run the full filter+**sort**, and hand *every* row to
SwiftUI's `ForEach` on **every body evaluation** — a tab switch, an Albums↔Songs toggle,
even a keystroke. At that scale each of those cost **1–2 s**. This is the on-device analog
of the online pager (§4): online is **server-paged** and already snappy, so this work is
**on-device only**. Search itself may still block briefly — the fix targets **browsing** and
**tab/kind switching**, which must be instant.

**Source of truth:**
[`apple/PocketDJ/State/AppModel.swift`](../../apple/PocketDJ/State/AppModel.swift)
(pre-built rows + `catalogRevision` + `cachedBrowseResults`),
[`apple/PocketDJ/Browse/BrowseState.swift`](../../apple/PocketDJ/Browse/BrowseState.swift)
(`resultsKey`, `results()`/`computeSorted`, `BrowsePaging`),
[`apple/PocketDJ/Views/BrowseView.swift`](../../apple/PocketDJ/Views/BrowseView.swift)
(the growing-prefix render).

```
 (1) PRE-BUILD ONCE — AppModel.applyEdits() → rebuildBrowseItems()
       albums/songs → albumBrowseItems / songBrowseItems  (name·source·genreCategory resolved)
       bumps catalogRevision ; clears the results memo
       ⇒ BrowseState.baseItems(app) is now an O(1) hand-off, NOT a per-render catalog map

 (2) MEMOIZE THE SORT — BrowseState.results(app):
       sorted = app.cachedBrowseResults( resultsKey ) { computeSorted(app) }   // base→query→clauses→SORT
       resultsKey = JSONEncoder(.sortedKeys) over {catalogRevision, kind, query, clauses, sortKeys}
       song-mode MEMBERSHIP + FAVORITE filters applied FRESH on top of `sorted`
         (applyReadTimeFilters — cheap O(n), never re-sorts, inputs live OUTSIDE the key §6.1)
       memo lives on AppModel (survives BrowseView re-creation on tab switch), @ObservationIgnored, cap 6

 (3) RENDER A GROWING PREFIX — BrowseView:
       page      = BrowsePaging.page(results, visible: liveVisible)     // first 120, then +120…
       liveVisible = (visibleKey == pagingKey) ? visibleCount : pageSize  // derived → resets SYNCHRONOUSLY
       onRowAppear(last) → grow ; focusReveal bounds keyboard-driven growth (no full-catalog blow-up)
```

**Reading the diagram.** Three independent moves make on-device browse cost **independent of
catalog size**. **(1)** The costly per-item derivation — building a `BrowseItem` for every
album/song with its album name, origin **source**, and top-tier **genre category** resolved —
now happens **once** in `AppModel.rebuildBrowseItems()` (called from `applyEdits()`, the single
catalog/edit rebuild point), stored on `albumBrowseItems`/`songBrowseItems`. `BrowseState.baseItems`
became an O(1) array hand-off instead of a full-catalog `map` on each render. **(2)** The
expensive base→text→clause→**sort** pass is **memoized** on `AppModel` (long-lived, so it
survives the `BrowseView` SwiftUI re-creates every time the Browser tab is re-entered), keyed by
`resultsKey` — a **JSON-encoded** signature (`.sortedKeys` for determinism; JSON string-escaping
makes it collision-proof where a delimiter-joined key wasn't) over the catalog revision, kind,
query, complete clauses, and sort keys. The song-mode **membership** (§6) and **favorite**
(§6.1) filters are layered on top of that cached sorted array as cheap `O(n)` predicates,
computed **fresh** each call (their inputs — the selected collections' contents, the ♥ set —
live outside the key), so they're never stale *and* never trigger a re-sort. **(3)** `BrowseView` hands `ForEach` only a **growing prefix**
(`liveVisible`, 120 per page) — the render-side cost that scaled with catalog size. `liveVisible`
is **derived** from a committed `visibleKey`, so a kind/filter switch collapses the budget to one
page **synchronously in the same render** (never a stale large prefix for a frame); the prefix
grows when the last rendered row appears (mirroring the online pager's `pageInIfLast`), and
`BrowsePaging.focusReveal` bounds keyboard-cursor growth so ↑-from-nothing (which seeds focus to
the last of ~105k rows) can't drag the budget out to the whole catalog. Measured at **100k songs**:
the default kind switch is **0.06 ms** and a warm memo hit **0.035 ms**, versus a **520 ms** cold
sort and the **~15 ms/render** full-catalog map that was removed from the render path.

## 8. Play history — the append-only per-play event log

**Source of truth:**
[`PlayHistoryStore.swift`](../../apple/PocketDJ/State/PlayHistoryStore.swift) (the durable log),
[`HistoryView.swift`](../../apple/PocketDJ/Views/HistoryView.swift) (the timeline UI),
[`CollectionActivityStore.swift`](../../apple/PocketDJ/State/CollectionActivityStore.swift)
(the add/heart/remove log behind the Activity segment, §8.1), and
[`BrowseState.swift`](../../apple/PocketDJ/Browse/BrowseState.swift) (`historyMode` / `refreshExternal` reuse).
User-facing counterpart: (STORYBOOK: [Play, Rip & Burn](../storybook/play-rip-burn.md)).

```
 record(songId, title, artist, context, at: nowMs)     ← every playback surface hooks here
   guard !songId.isEmpty
   dedupe: if lastPlayedIndex[songId], nowMs >= last, nowMs - last < recountWindowMs (30s) → return nil
   append PlayEvent{ id: UUID, songId, playedAt(epoch ms), source: PlaySource,
                     contextId?, contextName?, title?, artist? }  (snapshotted)
   lastPlayedIndex[songId] = max(…, nowMs);  countIndex[songId] += 1
   if events.count > maxEvents(20_000) → trimToCap() (removeFirst overflow)
   revision &+= 1;  save()  → atomic write

 Document{ schemaVersion, installId, events: [PlayEvent] }  → pocketdj-play-history.json
                              │
              ┌──────── HistoryView reuses ───────┐
   BrowseState(persistenceKey:"pdj.history.v1", historyMode:true)
     externalBase = buildItems()  (main actor: reads catalog)
     refreshExternal(signature, baseKey)  → filterSort OFF main actor → displayItems (paged)
```

**Reading the diagram.** `PlayHistoryStore` is a durable, **append-only** event log — one `PlayEvent` per listen — persisted to Application Support `pocketdj-play-history.json` with the same durable-JSON contract as its siblings (`CollectionsStore` / `PlayStatsStore`): atomic write, decode-on-`init`, and the `PDJ_USE_FIXTURE` launch seam (`launchURL()` hands UI tests an isolated, pre-cleared file). It belongs to the same data-model family as the other durable stores (Ch. 3), and is **fed by every playback surface** — the `PlaySource` enum (`browser`, `playlist`, `pocket`, `album`, `setlist`, `mix`, `artist`) names them, and each hook site resolves a `PlayContext` describing where the play happened. The enum's raw values are the persisted tokens and must never be renamed.

The critical design choice is that this is deliberately **not** `PlayStatsStore`. That store is an *aggregate* — one `playCount` + one `lastPlayedAt` per song, exactly what the storage manager's least-recently-played prune needs (Ch. 5 §9.2). History needs per-event granularity: the same song played three times in three sessions is three timeline rows, each carrying its own `playedAt` and the `contextName` of the set/mix it ran in. Do not conflate the two — they are separate stores fed by the same playback hooks, and the append-only shape exists precisely because *aggregate counters can't be merged idempotently* (you can't un-double a summed count).

Each `PlayEvent` **snapshots** its `contextId`/`contextName` and `title`/`artist` at record time. This is what makes rows survive the world changing underneath them: the timeline stays readable as "Friday Night Mix" even after that set is renamed or deleted, and a played song that later leaves the catalog still renders its name and artist (in `makeRow`, `app.songsById[e.songId]` falls back to `IndexSong.minimal(id:name:artist:)` built from the snapshot).

**The ~30 s same-song dedup window.** `record` collapses repeated plays of the *same* song inside `recountWindowMs` (30 000 ms) to a single event — a seek/restart, or the **burned-play double-hook** where the rip path and the coordinator both fire, is one listen, not two. The guard is `nowMs >= last, nowMs - last < recountWindowMs`: the `>=` is load-bearing — an *older* timestamp (out-of-order or clock-skewed play) has a negative delta that must not read as "within the window," so it is recorded as a genuinely distinct play. This constant is held equal to `PlayStatsStore.recountWindowMs` so the two stores agree on what counts as one listen.

**The 20 000-event cap.** Unlike the aggregate stats (bounded by song count), an append-only log grows without bound, so `maxEvents` caps it at 20 000 and `trimToCap()` drops the **oldest** events past the cap (`removeFirst(overflow)`), rebuilding the `lastPlayedIndex`/`countIndex` derived maps. A monotonic `revision` (`&+=`) is bumped on every real mutation so the History view can key its recompute on the store even when `events.count` is pinned at the cap.

**Shaped for a cross-profile merge.** Every event carries a stable `UUID` and the `Document` carries an `installId` (minted once at first `init`, preserved across `clear()`). The log now rides the CloudKit profile sync — registered with `CloudSyncService` as `"play-history"`, with a whole-document LWW `reloadFromDisk` on pull (which adopts the cloud doc's `installId`). A true event-level merge stays one step away: `union(events, by: id)` re-sorted by `playedAt` — dedupe is by event id, so re-importing the same log twice is idempotent (`CollectionActivityStore.reloadFromDisk`, §8.1, already merges exactly this way). `replaceAll` is the test/merge seam that swaps the whole log (re-caps, rebuilds indexes, persists).

**How `HistoryView` reuses the Browser.** Rather than a bespoke filter/sort engine, `HistoryView` drives its **own** `BrowseState` in `historyMode: true` under the distinct persistence key `"pdj.history.v1"`, so its filters/sort never clobber the Browser's. `historyMode` pins the state to song-kind, exposes the `historyOnly` `lastPlayedAt` field, and drops the collection-membership filter (rows are per-event, not per-song). The view seeds a default **Last-played** sort (`SortKey(field: "lastPlayedAt", dir: .desc)`) — most-recently-played first — and the `lastPlayedAt` field (`kind: .number`, op `.between`) powers a **date-range filter** ("played between May and August 2026") rendered as DatePickers in the `FilterSheet`.

The base rows come from the event log, not the catalog: `buildItems()` runs on the main actor (it reads the live catalog to resolve title/album/artwork), producing `[BrowseItem]` plus parallel search keys, which are handed to `BrowseState` via `externalBase`. `refreshExternal(signature:baseKey:)` then reuses that built base across query/filter/sort edits (rebuilding only when `baseKey` changes) and runs the actual **filter/sort off the main actor** (`Task.detached`, with a 180 ms debounce on an active text query). Rendering is **incrementally paged** — only a growing prefix (`liveVisible`) of the filtered+sorted result set is handed to `ForEach`, extended as the last visible row appears — because the log can reach tens of thousands of events. The paging key deliberately excludes `catalogRevision` so a catalog load (which re-resolves row metadata) doesn't strand a scrolled-in budget back at page one.

**Timeline vs By-song.** The Plays timeline is **always per-event** now — the Timeline/By-song mode picker was removed (Levi, 2026-07-18: the two reads were indistinguishable in practice). The `groupBySong` plumbing survives, pinned `false`, so the grouped engine (one row per song — the latest event as the representative plus a play `count` shown as "N plays") remains one flag away if a future view wants it. Each row's accessory line reads `<PlaySource.label> · <contextName> · <relative time>`.

**Entry points and seams.** History is reachable from anywhere via **⌘H** (`RootView.navigationShortcuts`'s hidden `"History-shadow"` button, which intentionally overrides the macOS system "Hide" shortcut) switching `section = .history`. The `PDJ_SEED_HISTORY` launch seam (`seedDemoIfRequested`, invoked from `RootView`) populates a deterministic handful of varied plays when the log is empty — self-contained (snapshot title/artist render before the catalog loads) and bypassing the re-count window via distinct timestamps; `PDJ_SEED_HISTORY_COUNT=N` seeds N distinct plays for exercising incremental paging.

### 8.1 The Activity segment — the collection-activity log (F11)

**The tab set (Levi, 2026-08-10).** History has exactly **three** tabs (`HistoryView.HistoryTab`):
**Playback** (the default), **For You** (only while the recommendation engine is on), and
**Collection**. The **Unified** view — plays and collection activity interleaved newest-first,
filtered by the search query alone — was **removed**; the owner's words were "playback, for you,
collection tabs only (remove unified)". What went with it is the ability to see a play and a
collection change *adjacent in time*; each stream survives whole in its own tab. Its only
exclusive action, the **Rewind to here** row menu, moved onto the Playback rows (which carry the
same `PlayRef.eventId` `rewindSlice` keys on). Nothing persisted the History tab — it is
per-appearance `@State`, so there was no stored `"Unified"` to migrate; the one stored
"where was I" seam, `SettingsStore.lastSection`, names the app SECTION, never a tab inside it.
The control itself now renders **every** available tab with the current one filled (it used to
show only the views you were *not* in — a trick that degenerates to a lone full-width button
once there are only two tabs left).

**Why a second store, not more `PlayEvent`s.** History carries **two event streams** behind that
control: song plays, and **collection activity** — "Added *X* to *Y*", "Hearted *Z*", "Removed
heart from *Z*", "Removed *X* from *Y*". `PlayEvent` is deliberately song-play-centric (the 30 s re-count window, the
`countIndex`/`lastPlayedIndex` aggregates feed recently-played reads), so an add/heart/remove
is a different **kind** of fact and gets its own append-only store —
`CollectionActivityStore`, persisted to `pocketdj-collection-activity.json` — with zero
wipe-risk to the play log. A merged single timeline was rejected for the same reason: Plays
rides `BrowseItem`, which is song-centric, and heart/remove rows have no clean song identity
to filter/sort alongside plays. Accordingly the Browser filter/sort toolbar drives the Plays
segment only (it is hidden on Activity); Activity is a plain **reverse-chronological** list —
kind-specific SF Symbol + snapshot headline + relative time, tap-through when the `itemId`
still resolves to a catalog song.

The store mirrors the `PlayHistoryStore` idiom on purpose: same durable-JSON contract
(atomic save, lenient decode-on-`init`, `PDJ_USE_FIXTURE` launch seam), the same
20 000-event `maxEvents` cap with oldest-first trim, a monotonic `revision`, stable per-event
`UUID`s + a document `installId`. `ActivityKind` raw values (`add`/`heart`/`unheart`/`remove`)
are persisted tokens — never rename. Events **snapshot** `itemTitle`/`collectionName` at
record time (rows survive renames/deletions; the live catalog title is preferred when the id
still resolves); `collectionId`/`collectionKind`/`collectionName` are nil for heart events (a
♥ isn't scoped to a collection).

Feeding is hook-shaped: `CollectionsStore` fires `onActivity` from its **user-facing**
add/remove paths (including the F11 **Recent** quick-add — `AddToCollectionView` surfaces the
top-3 most-recent still-resolving add targets from `CollectionsStore.recentAddTargets`), and
`FavoritesStore.onChanged` records heart/unheart for **user-originated** toggles only — sync
echoes never log. One deliberate divergence from the play log: this store's cloud-sync
`reloadFromDisk` (`"collection-activity"` registration) is a **union-by-event-id merge**, not
a whole-document LWW replace — an append-only, aggregate-free log can merge losslessly, and
LWW would let device B silently drop device A's local events.

---

## 9. The Artists browse kind — a whole discography, shuffled

**Source of truth:**
[`AppModel.swift`](../../apple/PocketDJ/State/AppModel.swift) (`buildEffective` — the artist grouping),
[`BrowseModel.swift`](../../apple/PocketDJ/Browse/BrowseModel.swift) (`BrowseItem.artist`, `ItemKind.artist`),
[`ArtistDetailView.swift`](../../apple/PocketDJ/Views/ArtistDetailView.swift) (Play all / Shuffle all),
[`CollectionsStore.swift`](../../apple/PocketDJ/State/CollectionsStore.swift) (`playNow(songIds:…, source:)`).

```
 ItemKind:  .album   .song   .artist          ← third browse kind (BrowseModel)
                                │
 AppModel.buildEffective (OFF main, once per catalog load):
   albums sorted (artist ⟂ name, localizedCaseInsensitive)
        │  single order-preserving pass, group CONSECUTIVE same-artist:
        └─ while albums[j].artist ≈ᶜⁱ artist { songCount += trackList.count; j++ }
              → .artist(name: albums[i].artist,           // FIRST casing wins
                        albumCount: j-i, songCount:,
                        artworkAlbumId: albums[i].id)
        stored as app.artistBrowseItems  (+ artistSearchKeys)

 BrowseView "Artists" tab ─tap─▶ Artist(name) ─▶ ArtistDetailView
        albums = app.albums.filter { $0.artist ≈ᶜⁱ artistName }
        allSongIds = albums.flatMap(\.trackList)
        ▶ Play all / 🔀 Shuffle all
              → CollectionsStore.playNow(songIds: allSongIds,
                        name: artistName, shuffle:, source: .artist)
                    → reserved Now Playing setlist (Ch. 4 §6)

 Plays attribute to History as PlaySource .artist (Ch. 6 §8)
```

**Reading the diagram.** `ItemKind` (`BrowseModel.swift`) has three cases — `album`, `song`, and `artist` — and the Artists tab in `BrowseView` is a first-class peer of Albums and Songs, not a view onto them. Where an album row wraps an `IndexAlbum` and a song row wraps an `IndexSong`, an artist row is a pure grouping value: `BrowseItem.artist(name:, albumCount:, songCount:, artworkAlbumId:)` carries just the artist name, its two counts, and a representative album id for the thumbnail. There is no `Artist` record in the catalog — the row is synthesized, and the artist's actual content (their albums, their tracks) is resolved by name on tap.

That synthesis is **always on-device**, and this is the load-bearing asymmetry with the other two kinds. `BrowseView.effectiveOnline` is `browse.searchOnline && browse.kind != .artist`: the online (OpenSearch/aoss) path covers albums and songs only, because the search index is built from those two corpora — there is no artist document to query. So while flipping the online toggle re-routes Albums and Songs to the server, the Artists kind silently stays on the local pipeline. A maintainer adding an online mode must not assume all three kinds have a server counterpart; artists are computed from the merged catalog every time, so they work identically offline and online.

The grouping lives in `AppModel.buildEffective`, computed off the main actor once per catalog load alongside the album/song browse rows (and re-run by `applyEdits` when a local edit is saved). Because `albums` is already sorted by `artist` then `name` (via `localizedCaseInsensitiveCompare`), the grouping is a single dictionary-free, order-preserving pass: walk forward while the next album's artist matches, accumulating `songCount` from each `trackList.count`, and emit one `.artist` row per run. The match is deliberately **case-insensitive** — `localizedCaseInsensitiveCompare(artist) == .orderedSame`. This is a real review-fix invariant, not an incidental nicety: a merged catalog whose sources disagree on casing ("OutKast" from vinyl, "Outkast" from Apple Music) sorts those albums adjacent (the sort is also case-insensitive) but, under a case-*sensitive* group boundary, would split them into two artist rows sharing the same `artist:<name>`-shaped id. The insensitive boundary keeps the discography whole; the **first** album's casing becomes the row's display name. The grouping key and the sort must stay case-agnostic in lockstep — diverge them and you reintroduce split artists with colliding ids.

Tapping an artist row pushes `Artist(name:)`, which `ArtistDetailView` resolves back into the discography with the *same* case-insensitive predicate: `app.albums.filter { $0.artist.localizedCaseInsensitiveCompare(artistName) == .orderedSame }`, then `allSongIds = albums.flatMap(\.trackList)` — every track, album by album, in catalog order. The header's **Play all** and **Shuffle all** both call `CollectionsStore.playNow(songIds: allSongIds, name: artistName, shuffle:, source: .artist)`, which snapshots those ids literally (no realize autofill or pocket sampling) into the reserved, reusable **Now Playing** setlist (Ch. 4 §6) and opens it autostarting — the same seam `AlbumDetailView` uses for a single album, just fed the whole discography. `shuffle` reorders the resolved tracks fresh on each call; **Shuffle all** is therefore a one-tap "play this artist's entire catalog on random," which is the kind's reason to exist.

`app.artistBrowseItems` had a second consumer until the owner replaced CarPlay's Albums and Artists tabs with **For You** (Ch. 7 §9); the head unit no longer browses artists, and `CarPlayModel.artists()` was deleted with the tab. The grouping is now single-consumer, and `ArtistDetailView` is where it lands. Every artist-initiated play is attributed to **Play history** as `PlaySource.artist` (Ch. 6 §8) — a distinct token (raw value `"artist"`, labelled "Artist", symbol `music.mic`) that sits beside `browser`/`playlist`/`pocket`/`album`/`setlist`/`mix`, so the timeline can tell "played from an artist's discography" apart from "played from an album." Because those raw values are the persisted history tokens, the `artist` case must never be renamed.

---

## 10. Targeted audio analysis — teaching feedback about *musicality*

Everything the recommenders score against is **metadata**: artist, genre, year, tempo, Camelot. So a 👍 can only ever mean "more of this artist" or "more of this genre" — `RecFeedbackStore` literally projects a verdict onto those two axes. A listener who likes the sparse, dry half of an artist's catalogue and dislikes the loud maximalist half has no way to say so, because both halves carry the same artist and the same genre.

**Why this is not simply "analyse the library."** A librosa pass costs ~11 s of CPU per song, and the catalogue is 107,757 rows — a 330 CPU-hour sweep, most of it spent on songs no one will ever be offered. Worse, only **1,939 rows (1.8%)** have local audio at all; the rest would have to be captured from Apple Music in real time first. So the analysis is *targeted*, and the target is the recommender's own output.

**The pipeline, in order.**

1. **v1 produces the candidates.** Unchanged. The ids are whatever `ForYouFeedBuilder.build` just froze — In Da Zone plus every crate's suggestion list.
2. **The device selects a bounded shortlist** (`RecAudioShortlist.select`, ~40 a night): the most **novel** (artist-level, `RecNovelty.ArtistFamiliarity`) and the most **similar to recent listening** (genre share, tempo, Camelot, renormalised over the axes this device can speak), **strictly alternating** rather than a fixed half-and-half — with a 50/50 split, a night where only three rows are eligible on the novel side ships a 94%-similar shortlist and calls it balanced.
3. **In-catalog only**, and structurally rather than by filter: candidates are looked up in `inputs.tracks`, so an id this device does not own has no row to contribute. That is what keeps the job bounded and why the 13-day bulk-rip problem does not apply.
4. **The nightly job analyses them** (`scripts/rec-audio-nightly.mjs`, launchd 02:00, hard stop 06:00) using the **existing** analyser — same Docker image, same `analyzeAudio`, same 90 s window as bpm/key, plus a new `analyze-timbre.py` stage.
5. **The vectors go back to the engine** as additional features (`rec/audio/<profileHash>.json`).

**What leaves the device: ids, nothing else.** The shortlist rides the existing `/events` flush as `audioQueue` — the same additive-optional doctrine as `feedback` and `playCounts`, so there is no second upload contract, no second retry policy and no second failure mode. It is a **set**, not a log: re-proposing an id the server already holds is a no-op, which is what makes a client that lost its `pendingIds` (a reinstall, a restore) harmless.

**The worker is profile-blind.** It holds no bearer key and cannot derive the scoped profile id (`HMAC(profileId, bearerKey)` — the key never leaves the device), so `GET /audio/queue` authenticates on the **enrollment secret alone** and hands back opaque profile hashes that the worker relays verbatim to `POST /audio/features`. Reporting an id — with a vector *or* as unanalysable — **drains it from the queue**, so a permanently undecodable song cannot sit at the head of the queue and be retried first every night forever.

**Stopping is correct, not failure.** `--until 06:00` is a hard deadline checked before each song starts, never a budget the job tries to fit into; the two sibling nightlies (`am-sync` 04:00, `digital-sync` 05:00) want the same Docker daemon. Work is resumable at song granularity — every completed vector is posted and drained — so a truncated night costs the night and nothing else. Songs with no local audio are **not** skipped: they are queued on the rip server's existing durable queue (`POST /rip-collection`, once each — `ripRequested` is what stops a song with no Apple Music match being re-requested nightly forever) and analysed on a later night once the capture exists.

**The 14 axes** are named things a person could say about a record — `bright`, `brightVar`, `air`, `width`, `noisy`, `fizz`, `punch`, `busy`, `dynamic`, `loud` — plus `m1…m4`, an unnamed spectral-envelope residual. Every value is normalised to 0…1 **at extraction time**, against a lo/hi table measured as the p02/p98 of the real catalogue, so a plain distance works without a per-feature scaler anywhere downstream. The first cut used plausible textbook ranges and three axes came back **dead** (`m1` pinned at 1.0 for 88% of songs, `m3` for 66%): a saturated axis is not a weak feature, it is a missing one that still costs a slot. `--raw` dumps the pre-normalisation values so the table can be re-derived; `TIMBRE_VERSION` is what makes the nightly job re-analyse after a recalibration instead of mixing two calibrations in one corpus.

**Analog songs are analysed from their per-song `cutKey`, never the album-level `key`** — the same rule `analyzeBeatgridForSong` follows. Reading `key` analyses the whole side and hands every track on it an identical vector; the first calibration run did exactly that and two eight-song artist groups came back with a pairwise distance of **0.0000**.

**Does it actually discriminate?** Measured on the owner's own ripped catalogue — 96 songs, 12 artist+genre groups: mean pairwise timbre distance **0.205 within one artist and genre** against **0.288 between groups** (ratio **0.71**), widest same-artist pair **0.705**, nearly 3× the between-group median. Songs that share an artist *and* a genre sit almost as far apart in timbre as songs that share neither. All 14 axes separate same-artist songs, led by `m2` (0.83 of its between-group spread), `brightVar` (0.80), `punch` (0.79) and `dynamic` (0.78) — i.e. *how much the brightness moves*, *drum-forward vs pad-forward*, *brickwalled vs breathing*. The signal is real.

**The ranking change is deferred, on purpose.** Nothing in `scoreForYou` reads the corpus yet. It starts empty and fills at ~40 a night against a 1.8%-ripped catalogue, so a timbre term switched on today would apply to a handful of candidates and none of the rest — not a weak signal but an **incomparable** one, with two songs ranked by different formulas and the tile reordering for reasons no verdict caused. The trigger conditions (≥ ~60% candidate-pool coverage; enough verdicts *on analysed songs* to define centroids; entry as a bounded multiplier like `NOVELTY_AUX_GAIN`) are written at the feature store in `scripts/lambda/rec-engine/index.mjs`.

---

## Next

→ [Chapter 7 — Distribution, Clients & the Edits Round-Trip](./07-distribution-and-clients.md)
