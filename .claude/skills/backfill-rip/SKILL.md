---
name: backfill-rip
description: Backfill out-of-streaming-catalog songs by local-ripping them. The Apple Music catalog-id crawl resolves PocketDJ songs → Apple Music storeIds so the app can stream them; songs that never resolve (storeId null) aren't in the streaming catalog. This skill takes that miss list (apple-music-catalog-misses.csv) and tells the rip server to local-rip each one from Apple Music (real-time capture → S3). Triggers on "backfill rip", "rip the misses", "rip the uncataloged songs", "rip out-of-catalog songs", "backfill the catalog misses".
---

# backfill-rip

The Apple Music **catalog-id crawl** (`scripts/`, output `index-out/apple-music/catalog-cache.ndjson`)
resolves each PocketDJ song → its **Apple Music storeId** so the app can stream it. Some
songs **never resolve** (`storeId === null`) — they are **not in the streaming catalog**, so
the app can't stream them.

This skill takes that miss list and tells the **iMac rip server** to **local-rip** each one
from Apple Music (real-time Audio Hijack capture → mp3 → public S3), backfilling a streamable
file for songs that otherwise can't stream. It reuses the rip server's batch endpoint
`POST /rip-collection`, the same durable queue + single-flight dedup as the in-app **Rip all**.

- **Worklist:** `apple-music-catalog-misses.csv` at the repo root (cols `songId,artist,title,
  album,albumId,year,trackNumber,lengthMs,fileType,source`).
- **Action:** `POST /rip-collection {songIds}` to the rip server (default `http://localhost:8787`).
  These have no catalog id, so the server local-rips them from Apple Music (real-time).
- **Idempotent:** the rip server skips songs already in the S3 manifest, so re-running is safe.
  The skill also reads the manifest up front and reports already-ripped vs to-rip.

## Prerequisites

- **Rip server running** — `scripts/rip-server.mjs` (launchd agent `com.pocketdj.ripserver`,
  default `http://localhost:8787`). It local-rips Apple Music via real-time Audio Hijack
  capture, so **ripping is real-time** (~song duration each, concurrency 1). See [[streaming-rips]].
  Override the URL/token with `--server` / `--token` (or `$RIP_TOKEN`) for the Tailscale host.
- **The misses CSV** — `apple-music-catalog-misses.csv` at the repo root. If it's missing or
  stale, regenerate it with `--refresh` (offline; needs the crawl outputs below).
- **For `--refresh`:** `index-out/apple-music/catalog-cache.ndjson` (the crawl cache) and
  `public/apple-music-index.json` (for the artist/title/album join).
- **For the idempotency check + `--watch`:** the `aws` CLI with profile **levi** (reads
  `s3://pocketdj-rips-011183829623/rips/manifest.json`). If it fails the skill still proceeds
  (the rip server dedups on its own).

## Usage

```bash
# Summary: total misses + top artists (no network, no selection):
node .claude/skills/backfill-rip/backfill-rip.mjs

# Regenerate the worklist from the latest crawl, then show the summary:
node .claude/skills/backfill-rip/backfill-rip.mjs --refresh

# Preview a selection (no network):
node .claude/skills/backfill-rip/backfill-rip.mjs --artist "Curren" --dry-run

# Rip a whole album's misses and watch until done:
node .claude/skills/backfill-rip/backfill-rip.mjs --album "Pilot Talk" --watch

# Rip specific songIds:
node .claude/skills/backfill-rip/backfill-rip.mjs --ids sng_aaa,sng_bbb

# Smoke run — rip the first 50 misses:
node .claude/skills/backfill-rip/backfill-rip.mjs --all --limit 50
```

| flag | default | meaning |
| --- | --- | --- |
| *(no args)* | — | print usage + summary (total misses, top artists). No network. |
| `--refresh` | off | regenerate the CSV from the latest crawl outputs (misses where `storeId===null`, joined to `apple-music-index.json`), then proceed |
| `--artist <substr>` | — | select misses whose **artist** contains `<substr>` (case-insensitive) |
| `--album <substr>` | — | select misses whose **album** contains `<substr>` (case-insensitive) |
| `--ids a,b,c` | — | select these exact songIds (comma-separated) |
| `--all` | off | select every miss |
| `--limit N` | all | cap the selection to the first N (applied after the filters) |
| `--dry-run` | off | preview the selected worklist + count, **no network** |
| `--watch` | off | after submitting, poll the S3 manifest every 15s until the selection finishes |
| `--server <url>` | `http://localhost:8787` | rip server base URL |
| `--token <token>` | `$RIP_TOKEN` | bearer token for the rip server |
| `--csv <path>` | repo `apple-music-catalog-misses.csv` | worklist CSV |

Selection flags combine (e.g. `--artist X --album Y --limit 10`). With **no** selection flag
(even after `--refresh`) the skill just prints the summary — you must pass `--artist`,
`--album`, `--ids`, or `--all` to actually submit a rip.

## How it works

1. **Worklist** — read `apple-music-catalog-misses.csv`. With `--refresh`, first regenerate it:
   stream `catalog-cache.ndjson`, keep rows where `storeId === null`, join each to
   `apple-music-index.json` (`songs[].{artist,name,length,...}` + `albums[].name`), and write
   the CSV sorted by artist/title. (This is exactly the set of un-streamable songs.)
2. **Select** — apply `--artist` / `--album` / `--ids` / `--all` + `--limit`.
3. **`--dry-run`** stops here, printing the selection + count.
4. **Idempotency** — read the S3 manifest (`aws --profile levi`) and report how many of the
   selection are **already ripped** vs **to rip**.
5. **Submit** — `POST /rip-collection {songIds}`. The server replies with a per-song status; the
   skill prints them and the counts:
   - **ready** — already in the manifest, nothing to do
   - **queued** — newly enqueued for a real-time local rip
   - **inflight** — joined an already-running rip
   - **unknown** — not in the rip server's catalog (won't rip; the server needs a re-index)
6. **`--watch`** (optional) — poll the S3 manifest every 15s until every queued/inflight song
   in the selection appears (i.e. its rip uploaded), printing progress.

## Notes

- **Real-time:** the rip server captures Apple Music playback live (concurrency 1), so a large
  selection takes roughly the **sum of the songs' durations**. Use `--limit` for a smoke run,
  then `--all` for the full backfill — re-running is safe (idempotent).
- **Idempotent end-to-end:** already-ripped songs come back `ready` and are skipped; you can
  re-run the same selection any time, or run without `--watch` and check later.
- **Refresh re-derives the misses** from the *current* crawl + index, so run `--refresh` after a
  fresh crawl to pick up newly-added or newly-resolved songs (a song that later resolves drops
  off the list; a newly-added un-streamable song joins it).
- The skill **edits nothing in the repo** except (re)writing `apple-music-catalog-misses.csv`
  when you pass `--refresh`. Without `--refresh` it only reads the existing CSV.
- For the remote rip server (off-LAN), point at the Tailscale host:
  `--server https://levis-imac.tail2e2bdf.ts.net --token "$RIP_TOKEN"`.
