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

- **Collection** `pocketdj-search` (id `zxvkpgoc5ivtrbqp37s5`, type SEARCH, NextGen,
  standby disabled → **scales to zero** when idle).
- **Index** `pocketdj`, endpoint
  `https://zxvkpgoc5ivtrbqp37s5.us-west-2.aoss.amazonaws.com`, SigV4 **service `aoss`**.
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

## Next

→ [Chapter 7 — Distribution, Clients & the Edits Round-Trip](./07-distribution-and-clients.md)
