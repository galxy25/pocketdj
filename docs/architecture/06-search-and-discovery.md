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

**Why.** Results used to be **capped at 60** — fine for a tight query, useless for
"every soul song." So online search now **pages**: `from/size` offset windows that the
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
       song-mode MEMBERSHIP filter applied FRESH on top of `sorted` (cheap O(n), never re-sorts)
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
query, complete clauses, and sort keys. The song-mode **membership** filter (§6) is layered on
top of that cached sorted array as a cheap `O(n)` filter, computed **fresh** each call (its
inputs — the selected collections' contents — live outside the key), so it's never stale *and*
never triggers a re-sort. **(3)** `BrowseView` hands `ForEach` only a **growing prefix**
(`liveVisible`, 120 per page) — the render-side cost that scaled with catalog size. `liveVisible`
is **derived** from a committed `visibleKey`, so a kind/filter switch collapses the budget to one
page **synchronously in the same render** (never a stale large prefix for a frame); the prefix
grows when the last rendered row appears (mirroring the online pager's `pageInIfLast`), and
`BrowsePaging.focusReveal` bounds keyboard-cursor growth so ↑-from-nothing (which seeds focus to
the last of ~105k rows) can't drag the budget out to the whole catalog. Measured at **100k songs**:
the default kind switch is **0.06 ms** and a warm memo hit **0.035 ms**, versus a **520 ms** cold
sort and the **~15 ms/render** full-catalog map that was removed from the render path.

## Next

→ [Chapter 7 — Distribution, Clients & the Edits Round-Trip](./07-distribution-and-clients.md)
