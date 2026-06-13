---
name: analog-indexer
description: Index a PocketDJ "analog" data source (vinyl recordings) from a text file of ArtistNameAlbumNameRaw filenames into a music index.json the app loads. Triggers on "index the vinyl", "run analog-indexer", "build the music index", "index Vinyl.md". Long, resumable, network-heavy batch job (iTunes + web/Wikipedia fallback + Haiku sentiment).
---

# Analog Indexer

Turns a text list of vinyl recording filenames (`ArtistNameAlbumNameRaw.<ext>`, every
vinyl line contains the marker `Raw`) into the canonical PocketDJ index
(`index-out/index.json`) that the app imports as an **analog** data source.

For each vinyl line it creates one **album** item, then finds the album's **songs**
and creates **song** items. Metadata it fills (web-findable only): artist, album,
genre, year, country, cover art, tracklist, track length, explicit flag, lyrics,
and Haiku **sentiment keywords**. It DEFERS `bpm`, `key`, and per-track
`timestamps` (those need the audio file).

## Architecture (Node does the fetching; a Workflow does only the LLM work)

The deterministic enrichment (iTunes match + tracklist + country + lyrics) is just
HTTP and needs no model — so it runs **concurrently in Node** (≈0.7s/album, vs
~2min/album inside a sequential agent loop). Agents are reserved for what genuinely
needs a model: the **Wikipedia fallback** for unmatched albums and **Haiku
sentiment**. (Workflow scripts can't touch the filesystem, so Node owns parse/
enrich/merge and the workflow only computes sentiment.)

```
data/Vinyl.md
   │ (1) parse     node lib/cli.mjs parse …             -> index-out/parsed-*.json
   ▼
parsed candidates
   │ (2) enrich    node lib/enrich.mjs …                -> index-out/shards/batch-*.json   (FAST, deterministic)
   ▼                  (iTunes match+lookup, opt MusicBrainz country, capped lyrics.ovh)
enriched shards
   │ (3) sentiment node lib/build-sentiment.mjs … ; Workflow({scriptPath}) ; --stitch     (Haiku)
   ▼
   │ (4) merge     node lib/cli.mjs merge index-out/shards … -> index-out/index.json
   ▼                                                          + coverage-report.json + run-log.json
app import (src/storage/importIndex.ts)
```

## How to run (the fast path)

**1. Parse** (gate on `Raw`, strip it, split CamelCase; `--limit N` for a sample):
```
node .claude/skills/analog-indexer/lib/cli.mjs parse data/Vinyl.md \
  --out index-out/parsed-full.json --location "Vinyl crate A"
```

**2. Enrich** (concurrent; `--country` adds MusicBrainz, `--lyrics-cap N` bounds lyrics):
```
node .claude/skills/analog-indexer/lib/enrich.mjs index-out/parsed-full.json \
  --out-dir index-out/shards --concurrency 12 --lyrics-cap 6 --country
```
Writes `index-out/shards/batch-XXXX.json` = `{ batchIndex, albums: EnrichedAlbum[] }`.

> **⚠ iTunes rate limits.** Apple's Search API throttles aggressively (~20 req/min/IP).
> A fast unthrottled run on the full 1,366 catalog gets blocked (HTTP 403) after ~50
> albums → mass `unmatched`. For the **full catalog**, throttle and let it run in the
> background (the enricher serializes iTunes calls and backs off on 403/429):
> ```
> node .../enrich.mjs index-out/parsed-full.json --out-dir index-out/shards-full \
>   --concurrency 1 --itunes-delay 900 --retries 6 --lyrics-cap 1
> ```
> ~40–60 min for 1,366 albums. If the IP is already throttled, give it a cooldown
> (minutes–1h) first. Re-running is idempotent; you can also `--slice A:B` to chunk,
> and re-run just the `unmatched` ones later (optionally via the Wikipedia agent path).
> A small curated set (e.g. 15–150 albums) runs fine without throttling.

**3. Sentiment (Haiku)** — build a self-contained run script from the shards, launch
the workflow, then stitch its results back:
```
node .claude/skills/analog-indexer/lib/build-sentiment.mjs index-out/shards \
  index-out/run-sentiment.workflow.js --size 60
Workflow({ scriptPath: "index-out/run-sentiment.workflow.js" })     # returns { results:[{sk,keywords,source}] }
# write the returned results to index-out/sentiment-results.json, then:
node .claude/skills/analog-indexer/lib/build-sentiment.mjs --stitch index-out/shards index-out/sentiment-results.json
```

**4. Merge** into the canonical index + reports:
```
node .claude/skills/analog-indexer/lib/cli.mjs merge index-out/shards \
  --out-dir index-out --source Vinyl.md --lines 1372 --vinyl 1366 --size 50
```

## Wikipedia fallback (agent path) for unmatched albums

`enrich.mjs` marks albums iTunes can't match as `status:"unmatched"` (no tracks).
To fill those from the web, the agent-based `workflow/index-vinyl.workflow.js`
(built via `lib/build-run.mjs`) does iTunes **and** a plain web/Wikipedia search for
the tracklist. Run it over just the unmatched candidates when you want to recover them.

## Resuming the long full run

- Enrich is restartable: it overwrites shards by batch; re-running re-fetches.
- Content-derived ids (`alb_*/sng_*`) make merge idempotent.
- The sentiment Workflow supports `resumeFromRunId` (cached Haiku batches replay).

## Enrichment sources & order (per album)

1. **iTunes Search/Lookup** (keyless) — primary; fills artist/album/genre/year/cover/
   tracklist/length/explicit. Fuzzy-match the whole "Artist Album" blob (no split needed);
   compilations ("Greatest Hits"/"Best Of") are expected, not penalized.
2. **Web search / Wikipedia** — FALLBACK when iTunes misses or returns no tracks;
   read the album's track listing. (Never search the word "Raw".)
3. **MusicBrainz** (keyless, ~1 req/s, needs User-Agent) — Country (artist area).
4. **lyrics.ovh** (keyless) — per-track lyrics, best-effort single attempt.
5. **Haiku** — sentiment keywords from lyrics, or inferred from context when absent.

## Outputs

- `index-out/index.json` — canonical index (see `docs/SCHEMA.md`, `schema/index.schema.json`, `docs/LOADER_CONTRACT.md`).
- `index-out/coverage-report.json` — match/lyrics/sentiment scorecard.
- `index-out/run-log.json` — per-album provenance (sources, match decisions). The
  indexer's proof-of-verification artifact.

## Files

- `lib/parser.js` `lib/normalize.js` `lib/itunes.js` `lib/ids.js` `lib/assemble.js`
  `lib/merge.js` `lib/batching.js` — pure helpers (Node, unit-tested via `lib/parser.test.mjs`).
- `lib/cli.mjs` — parse / plan / merge entry points.
- `lib/build-run.mjs` — generates the embedded run script.
- `workflow/index-vinyl.workflow.js` — the enrichment Workflow (template).
- `prompts/` — human-readable copies of the agent prompts.
- `schema/` — index schema + agent output schemas.
