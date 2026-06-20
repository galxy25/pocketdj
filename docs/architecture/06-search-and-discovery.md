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
  each run** (corpus small → ~40s); `_id = item id` so re-runs upsert.
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
   { size, query:{ bool:{
       must:[ multi_match{ query, fields:["title^3","artist^2","album^1.5","lyrics","sentiment^2"],
                           type:"best_fields", fuzziness:"AUTO", operator:"and" } ],
       filter:[ term{type}? , terms{source}? ] }}}

 HIT    { _id, _source: EsHitSource }
   EsHitSource { id,type,title?,artist?,album?,albumId?,genre?,year?,bpm?,key?,
                 camelot?,explicit?,sourceType?,source?,trackNumber? }
 SIGN   SigV4 service="aoss" · host;x-amz-content-sha256;x-amz-date(;…token)
```

**Reading the diagram.** The query is a `bool` with a boosted `multi_match` `must`
across title/artist/album/lyrics/sentiment (`AND`, fuzzy) and optional `term`/`terms`
filters on `type` and `source` — identical on web and native. A hit is `{_id,
_source}`; `_source` is the flat `EsHitSource`. Signing uses SigV4 service `aoss` with
the listed canonical headers, which is why the CloudFront proxy must preserve Host.

**How (worked example): "midnight".** The browser POSTs the multi_match body to
`/pocketdj/_search`; CloudFront forwards to aoss; aoss returns
`hits.total.value = 470`, hits capped at `size`. `esSearch()` maps each to a
`SongItem`/`AlbumItem`, reports `total=470` + `tookMs`, and the grid shows "80 of 470"
with E and BPM/key badges — same query, same fields, web or native.

---

## 5. Discovery surfaces (the catalog side)

Search is the precise lookup; the **star map** is the spatial discovery lens. Both
read the same loaded catalog (Ch. 3) — grouping by **genre / BPM band / Camelot key**
is pure client-side derivation over `SongItem.genre`, `bpm`, and `camelot` (the
storybook §1–§4). No backend involvement; this is why discovery works fully offline.

## Next

→ [Chapter 7 — Distribution, Clients & the Edits Round-Trip](./07-distribution-and-clients.md)
