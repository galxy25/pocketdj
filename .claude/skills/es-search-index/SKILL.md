---
name: es-search-index
description: Build / refresh the PocketDJ OpenSearch (Serverless, aoss) full-text search index from the app's index.json sources. Triggers on "reindex search", "update the search index", "rebuild elasticsearch index", "refresh opensearch". FULL RESET each run (delete + recreate + bulk load); fast because the corpus is small. AWS profile levi.
---

# OpenSearch Search Index (es-search-index)

Loads every album + song from the app's `index.json` sources into the
**OpenSearch Serverless** collection `pocketdj-search` (NextGen, scale-to-zero),
into the index `pocketdj`, so the app's **online search mode** can query it.

Searchable fields: **title** (song + album), **artist**, **album**, **lyrics**
(optional), **sentiment** keywords, plus filters: genre, year, bpm, key, camelot,
explicit, type (album/song), sourceType (analog/digital), source (name).

**Reference run:** 118,971 docs (13,581 albums + 105,390 songs across both
sources) — delete + recreate + bulk load in **~40s**.

## Backend (already provisioned, profile `levi`, us-west-2)
- Collection: `pocketdj-search` (id `zxvkpgoc5ivtrbqp37s5`), type SEARCH, NextGen, standby DISABLED → **scales to zero** when idle.
- Endpoint: `https://zxvkpgoc5ivtrbqp37s5.us-west-2.aoss.amazonaws.com`
- SigV4 **service = `aoss`** (not `es`).
- Policies: network `pocketdj-net` (public), data `pocketdj-data` (Developer = full, djpocketsearch = read-only).
- Read-only app user: **djpocketsearch** (`aoss:ReadDocument`/`DescribeIndex`); creds in `~/Downloads/djpocketsearch-credentials.json`. The app uses these; they CANNOT write (verified: DELETE → 403).

## Reindex (FULL RESET — the normal operation)
Indexing is cheap, so each run **deletes and recreates** the index, then bulk-loads
everything. The write path signs as **levi** (the Developer admin, granted write by
the data access policy).

```bash
cd <repo>            # a worktree with public/*.json present
node scripts/es-index.mjs \
  --endpoint https://zxvkpgoc5ivtrbqp37s5.us-west-2.aoss.amazonaws.com \
  --index pocketdj --profile levi --region us-west-2 \
  --sources public/current-index.json,public/apple-music-index.json,public/digital-index.json
```

> Include **every** `public/*-index.json` source each run — it's a FULL RESET, so any source
> omitted from `--sources` is dropped from search. `digital-index.json` ("My Digital", 43 albums /
> 602 songs) is part of the set; the nightly `am-sync-nightly.sh` `ES_SOURCES` default includes it.

To update what's searchable, regenerate the source `index.json`(s) first (see the
`analog-indexer` / `apple-music-indexer` skills), then re-run the command above.
The app's online mode picks up changes immediately (collection is shared).

> **Automated nightly.** The Apple Music sync job (`scripts/am-sync-nightly.sh`, launchd @ 04:00)
> runs this exact reindex automatically whenever it ships a changed catalog — so a newly-added
> track is in online search the same night, no manual run needed. It's non-fatal there and
> skippable with `POCKETDJ_SKIP_ES=1`. See `docs/apple-music-sync.md`.

### Include lyrics (optional)
Lyrics are not in the lean index.json (they live as per-song `.txt` on the CDN).
Pass `--lyrics-base <cdn>` to fetch `/lyrics/<songId>.txt` for each song and index
the text (bounded concurrency):

```bash
node scripts/es-index.mjs … --lyrics-base https://d2p4cubg6se03u.cloudfront.net
```

## How it works (scripts/es-index.mjs)
- Reads each `--sources` index.json, emits one doc per album + per song (title,
  artist, album, sentiment, genre, year, bpm/key/camelot, explicit, type, source).
- Hand-rolled **SigV4 (service aoss)**; creds via `aws configure export-credentials --profile levi`.
- `DELETE /pocketdj` (ignore 404) → `PUT /pocketdj` with the mapping → `POST /pocketdj/_bulk` in 1,500-doc batches → `_refresh`.
- Serverless note: `_count` may lag a few seconds after bulk (async commit) — it catches up; re-run `_count` to confirm.

## App side (how online mode reaches it)
The browser has **no CORS** to aoss directly, so it queries a **same-origin path**
`/pocketdj/_search` that a **CloudFront behavior** forwards to the aoss origin
(preserving Host so the browser's SigV4 — signed for the aoss host — validates).
The browser signs with the djpocketsearch key/secret the user enters in
**Settings ▸ Online search**, and the **online/offline toggle** (offline default)
only appears once those creds are set. See `src/search/esClient.ts` +
`src/search/sigv4.ts`.

## Mapping invariants (keep in sync with src/search/esClient.ts)
- `_id` = the item id (`alb_…` / `sng_…`) → re-runs upsert the same docs.
- `title`/`artist`/`album` are `text` with a `.kw` keyword subfield (exact/sort).
- Query: `multi_match` over `title^3, artist^2, album^1.5, lyrics, sentiment^2`,
  `fuzziness: AUTO`. Filters: `term type`, `terms source`.
- Index name `pocketdj` MUST equal the CloudFront proxy path prefix (`/pocketdj`)
  so the browser's signed path matches what aoss receives.

## Teardown / cost
Collection scales to **$0 compute at idle** (NextGen); you pay only managed storage
(~pennies for this corpus). To remove entirely:
`aws opensearchserverless delete-collection --id zxvkpgoc5ivtrbqp37s5 --profile levi --region us-west-2`
(then delete the `pocketdj-net` / `pocketdj-data` policies and the djpocketsearch user).
