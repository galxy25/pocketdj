---
name: analog-indexer
description: Index a PocketDJ "analog" data source (vinyl recordings) from a text file of ArtistNameAlbumNameRaw filenames into a music index.json the app loads. Triggers on "index the vinyl", "run analog-indexer", "build the music index", "index Vinyl.md". Long, resumable, network-heavy batch job (Discogs + web/Wikipedia + Claude/local-model sentiment).
---

# Analog Indexer

Turns a text list of vinyl recording filenames (`ArtistNameAlbumNameRaw.<ext>`, every
vinyl line contains the marker `Raw`) into the canonical PocketDJ index
(`index-out/full/index.json`) that the app imports as an **analog** data source.

For each vinyl line it creates one **album** item, then finds the album's **songs**
and creates **song** items. Metadata it fills (web-findable only): artist, album,
genre, year, country, cover art, tracklist, track length, explicit flag, lyrics,
and **sentiment keywords**. It DEFERS `bpm`, `key`, and per-track `timestamps`
(those need the actual audio file).

Final shipped catalog: **1361 albums, 100% matched, 100% sentiment-tagged.**

## Pipeline architecture (streaming, manifest-driven)

The indexer is a chain of **decoupled sub-indexers**, each filling its own fields and
carrying every record forward. It is **streaming**: each stage owns an append-only
JSONL file in a shard dir (default `index-out/shards-pw/`), and the **index doubles as
the manifest** — the set of stage files plus per-album stage stamps records *what each
stage did per album*, so any stage is **resumable** and can be re-run **selectively**
(process only items where its stage isn't done). Resumability and selective re-indexing
are the same mechanism. A slow stage never blocks a faster upstream one.

```
parse → [1 metadata] → [2 backfill + singles] → [3 lyrics] → [4 sentiment] → merge → [5 audio]
         Discogs/Wiki    WebSearch agents /        Genius/      Claude agents /            librosa
         (Playwright)     browser fallback;         AZLyrics     local Gemma (LM Studio)    (Docker)
                          synth-singles             (Playwright)
```

Stages 1–4 produce the merged `index.json`. Stage 5 (**audio** — BPM/key/timestamps) and
the **backfill folds** (covers, lyrics, upgraded sentiment) run OUT OF BAND and are folded
into the already-merged index in place by the `lib/apply-*.mjs` scripts — see
"Out-of-band stages & live-index folds" below. They need the audio files / a second data
pass, so they aren't part of the streaming merge.

Stage files in the shard dir (overlaid in this read order by `lib/manifest.mjs`
`buildFromStages`):

| file | stage | written by |
| --- | --- | --- |
| `enriched.jsonl` | metadata | `enrich-playwright.mjs` (+ `synth-singles.mjs` folds singles in) |
| `google.jsonl` | recovery (browser) | `enrich-google.mjs` / `scripts/run-backfill.sh` |
| `web.jsonl` | recovery (WebSearch) | Claude WebSearch agents (preferred backfill) |
| `lyrics.jsonl` | lyrics | `enrich-lyrics.mjs` |
| `sentiment.jsonl` | sentiment | `enrich-sentiment.mjs` (local) or `sentiment-claude-merge.mjs` (Claude) |

The **audio** stage (BPM/key/timestamps) and the cover/lyrics/sentiment **backfills** are
out-of-band: they produce their own JSONL (`audio.jsonl`, `covers-backfill.jsonl`,
`lyrics-backfill.jsonl`, sentiment-upgrade `out/*.jsonl`) and are folded into the merged
`index.json` by the `lib/apply-*.mjs` scripts rather than the streaming overlay.

**Manifest merge ownership (load-bearing).** `buildFromStages` reads the stage files in
the order above. The metadata + recovery stages (`enriched`/`google`/`web`) **OWN the
album-level fields** (status, artist, name, year, genre, tracks): they merge whole, and
a recovered (matched, with-tracks) record supersedes the trackless "unmatched"
pass-through. The lyrics + sentiment stages **only contribute track data** (lyrics,
keywords) + their own stage stamp — their carried-forward copy of the album fields can
be stale (written while the album was still "unmatched"), so they must **not** override
a recovery's matched status or wipe its tracks.

## Run it (full pipeline)

`scripts/run-pipeline.sh` runs lyrics + sentiment as streaming workers behind the
metadata scraper; `scripts/run-backfill.sh` does the browser-recovery backfill;
`lib/pipeline.mjs` gives status + the final merge.

```bash
# 1. parse the vinyl list (gate on `Raw`, strip it, split CamelCase)
node .claude/skills/analog-indexer/lib/cli.mjs parse data/Vinyl.md \
  --out index-out/parsed-full.json --location "Vinyl crate A"

# 2. METADATA (background): the Playwright scraper streams enriched.jsonl
node .claude/skills/analog-indexer/lib/enrich-playwright.mjs index-out/parsed-full.json \
  --out-dir index-out/shards-pw --concurrency 3 --progress-file index-out/meta-progress.log

# 3. BACKFILL still-unmatched albums (see "Metadata backfill" below)
#    PREFERRED: Claude WebSearch agents -> index-out/shards-pw/web.jsonl
#    FALLBACK:  scripts/run-backfill.sh -> index-out/shards-pw/google.jsonl
#    Then fold leftover 12" singles into one-track albums:
node .claude/skills/analog-indexer/lib/synth-singles.mjs --dir index-out/shards-pw

# 4. LYRICS + SENTIMENT streaming workers (metadata can still be running)
scripts/run-pipeline.sh                         # lyrics + local-model sentiment
SENT_MODE=claude scripts/run-pipeline.sh        # lyrics only; do sentiment via the Claude path

# status (per-stage coverage) over the streaming stage files
node .claude/skills/analog-indexer/lib/pipeline.mjs status --dir index-out/shards-pw

# 5. MERGE the overlaid stages -> index.json + reports
node .claude/skills/analog-indexer/lib/pipeline.mjs merge --dir index-out/shards-pw \
  --out-dir index-out/full
```

There is also a **manifest-file mode** of `pipeline.mjs` (`import-metadata`, `run
--stages lyrics,sentiment`, `redo <stage> [--failed]`, `merge`) that keeps a single
`index-out/manifest.jsonl` instead of separate stage files. Both modes share the same
stage stamping; the streaming `--dir` mode is what the full run uses.

## 1. Metadata stage (`lib/enrich-playwright.mjs`)

Headless-Playwright enricher. Two captcha-free sources queried from **inside a real
Chromium page context** (requests carry a genuine browser fingerprint):

1. **Discogs public API** (`api.discogs.com`, **no token needed**) — PRIMARY. Richest
   data: structured tracklist (vinyl side positions `A1`/`B2` → disc number), year,
   genres+styles, country, hi-res cover. Throttled (~1 call/2.6 s on one shared lane,
   ≈25 req/min unauthenticated); backs off 30 s on 429/403. Note: Discogs search returns
   the most-prevalent *pressing*, so the year can be a reissue year, not the original.
2. **Wikipedia** (REST search → article scrape) — FALLBACK when Discogs misses/throttles.
   Infobox (genre, year, cover) + `table.tracklist`.

```bash
node lib/enrich-playwright.mjs <parsed.json> --out-dir index-out/shards-pw \
  [--concurrency 3] [--size 100] [--limit N] [--slice A:B] [--progress-file PATH] [--album-timeout 45000]
```

Politeness: `--concurrency` clamped to **2–4** pages (one reused page per worker,
image/font/css blocked), small random delays, desktop-Chrome UA, per-album timeout so
one slow page can't stall the pool. **Never throws out of the pool** — failures emit
`status:"unmatched"` with `tracks:[]`. **Resumable + durable:** each completed album is
appended to `enriched.jsonl` immediately; on restart it skips already-done candidates.
(The website HTML for Discogs and Google serve bot captchas to headless Chromium — this
is why we hit the Discogs *API* + Wikipedia, not their search pages.)

## 2. Backfill for unmatched albums

After the metadata pass, albums still `status:"unmatched"` (Discogs/Wikipedia couldn't
match them) get a second look.

### PREFERRED — parallel Claude WebSearch agents → `web.jsonl`

A **Workflow** fans the unmatched albums out to parallel Claude **WebSearch** agents
that identify the real release + tracklist and emit matched records to
`index-out/shards-pw/web.jsonl`. This is **captcha-free** (no browser), fast, and
high-yield. `manifest.mjs` reads `web.jsonl` as a recovery stage, so a recovered record
supersedes the trackless pass-through. This is the path used for the full index.

### FALLBACK — browser web-search (`lib/enrich-google.mjs` + `scripts/run-backfill.sh`)

Captcha-prone. Searches the web in a **real headed browser, the way a person would**:
open the search engine's homepage, type the query into the box, submit (headless
direct-URL requests get captcha-walled; a real headed Chrome typing into the box usually
isn't). Cycles **Google → DuckDuckGo → Bing** per album, optionally a second sweep via
**Safari** (AppleScript). A local model (Gemma via LM Studio) extracts the tracklist +
metadata from the results page; if the model is **unavailable** the album is **deferred,
not written**, so a re-run retries it. Recoveries land in `google.jsonl`.

```bash
scripts/run-backfill.sh                 # 3 chrome shards, google→ddg→bing
SHARDS=4 scripts/run-backfill.sh        # more parallelism
SAFARI=1 scripts/run-backfill.sh        # add a Safari sweep over stragglers
```

Each parallel shard MUST use its own `--profile-dir` (Chrome locks a profile to one
process); `run-backfill.sh` handles that.

### Singles synthesis (`lib/synth-singles.mjs`)

Albums still `unmatched` after BOTH backfills are almost always 12" **singles** /
individual tracks with no album tracklist to match. Rather than drop them, this turns
each into a **one-track album** (`name = "<single name> Single"`, one track = the single
itself) folded **in place** into `enriched.jsonl` (backs up `.bak` first), and drops
those candidateIndexes from `lyrics.jsonl`/`sentiment.jsonl` so the streaming workers
re-process them. **Idempotent** (skips records already tagged `single-synth`; never
touches albums recovered by `web`/`google`).

```bash
node lib/synth-singles.mjs --dir index-out/shards-pw
```

## 3. Lyrics stage (`lib/enrich-lyrics.mjs`)

Headless-Playwright sub-indexer run AFTER metadata. Reads `enriched.jsonl`, ADDS each
track's `lyrics` (trimmed) + `lyricsStatus` (`found`/`notfound`), carries every record
forward verbatim, writes `lyrics.jsonl`.

```bash
node lib/enrich-lyrics.mjs --in index-out/shards-pw/enriched.jsonl \
  --out index-out/shards-pw/lyrics.jsonl \
  [--concurrency 3] [--cap N] [--limit N] [--slice A:B] [--progress-file PATH] [--song-timeout 25000]
```

Per track it cycles two providers:

1. **Genius** (PRIMARY): in-page search → `page.goto` the song → scrape every
   `[data-lyrics-container]` (keeps `[Verse]/[Chorus]` headers; strips the leading
   "N Contributors / … Lyrics" chrome + trailing "Embed").
   > **Same-origin gotcha (load-bearing):** `genius.com/api/*` is CORS-locked, so an
   > in-page fetch from any other origin returns `status:0`. The worker page must be ON
   > `genius.com` first; the stage lands on the genius.com home once per worker and
   > reuses that origin. Without this, **zero** lyrics resolve.
2. **AZLyrics** (FALLBACK): slugged URL `azlyrics.com/lyrics/<artist>/<title>.html`.
   > **Bot wall (current):** AZLyrics serves headless Chromium a 200-status "request for
   > access" interstitial for every request; the stage detects it and backs the lane off
   > 60 s. **So in practice all lyrics come from Genius today.**

**Oversized-scrape rejection (load-bearing):** a scrape over **`MAX_PLAUSIBLE_LYRICS`
= 20000 chars** is almost always a whole-page dump (nav/comments/blobs), NOT lyrics —
it's REJECTED (returned as `''` → treated as `notfound`) rather than poisoning the index
with garbage. Accepted text is also validated (>60 chars, has line breaks, not an
error/redirect page) and trimmed (~3000 chars). Resumable + durable like the other
stages; unmatched/empty albums pass through untouched. `--cap N` limits to the first N
tracks per album.

## 4. Sentiment stage — TWO supported paths

Both fill each song's `sentimentKeywords` (3–7 lowercase mood/theme keywords) +
`sentimentSource` (`lyrics` when derived from real lyrics, else `inferred`) and write
`sentiment.jsonl` in the same shape.

### A. Local model (`lib/enrich-sentiment.mjs`) — good for incremental adds

A LOCAL model served by **LM Studio's OpenAI-compatible API** (default
`http://127.0.0.1:1234`, model `google/gemma-4-e4b`). No cloud key. Gemma is a
*reasoning* model, so two guards are essential:

- `--max-tokens` (default **2000**): the real output is tiny (~50 tokens of JSON); a huge
  cap just lets the reasoning model ramble/loop for tens of thousands of tokens and stall
  a song for minutes (64k once hung a song 20+ min).
- `--timeout` (default **75000 ms**): a per-request wall-clock cap so one rambling
  generation can't pin a model slot forever — on timeout it aborts, marks the song
  failed, and moves on.

```bash
node lib/enrich-sentiment.mjs --in index-out/shards-pw/lyrics.jsonl \
  --out index-out/shards-pw/sentiment.jsonl \
  [--concurrency 2] [--batch 1] [--max-tokens 2000] [--timeout 75000] [--model google/gemma-4-e4b] [--progress-file PATH]
```

Resumable (skips albums already in `--out` by candidateIndex), per-album durable.
`scripts/run-pipeline.sh` runs this as the sentiment worker by default (`SENT_MODE=local`).

### B. Claude agents (the Claude WORKFLOW) — ~100% coverage, far faster; used for the full index

Set `SENT_MODE=claude` so `run-pipeline.sh` runs **lyrics only** and sentiment is done
out of band by Claude sub-agents:

```bash
# 1. emit the sentiment TODO (every matched album w/ an un-tagged song, with lyrics
#    where the lyrics stage found them) from the full stage overlay:
node lib/sentiment-todo.mjs --dir index-out/shards-pw --out /tmp/sent-todo.jsonl

# 2. run the Claude sentiment Workflow: it fans slices of the todo out to parallel
#    sub-agents that emit COMPACT per-track keyword results to part files
#    {"ci":N,"results":[{"i":0,"keywords":[...],"source":"lyrics"|"inferred"}, ...]}

# 3. merge the part files back into full album records, appended to sentiment.jsonl
#    in the same shape the local path produces (resumable: skips albums already in --out):
node lib/sentiment-claude-merge.mjs --todo /tmp/sent-todo.jsonl \
  --parts <parts-dir> --out index-out/shards-pw/sentiment.jsonl
```

(`workflow/sentiment.workflow.js` is the older Haiku-by-ordinal Workflow, fed by
`lib/build-sentiment.mjs --stitch`; the `sentiment-todo` + `sentiment-claude-merge` pair
is the current full-index path because it reads the streaming overlay directly.)

### C. Incremental sweep — local sentiment IN PARALLEL with lyrics (`scripts/sentiment-sweep.sh`)

When lyrics are still streaming in (e.g. a long backfill pass), don't wait for them to
finish before tagging sentiment. `sentiment-sweep.sh` re-runs the **local** sub-indexer
over the **growing** lyrics-output file every `POLL` seconds; because `enrich-sentiment.mjs`
is resumable (skips albums already in `--out`), each pass only tags the newly-arrived
albums. It keeps sweeping until the upstream producer process exits, then does one final
catch-up pass. Lyrics is network-bound and the local model is GPU-bound, so the two run
concurrently without contending.

```bash
IN=/tmp/lyrics-out.jsonl OUT=/tmp/sentiment-out.jsonl SENT_CONC=2 scripts/sentiment-sweep.sh
# knobs: IN, OUT, SENT_CONC, POLL (default 180), SENT_MODEL, UNTIL_PROC (default enrich-lyrics.mjs)
```

### D. Re-derive `inferred` → `lyrics`-sourced (the Claude/Haiku UPGRADE workflow)

A song tagged `sentimentSource:"inferred"` (sentiment guessed from title/artist/genre
because it had no lyrics yet) should be **re-derived from the real lyrics** once it has
them — a quality pass, not new coverage. `workflow/sentiment-upgrade.workflow.js` does
this with **Opus orchestrating + Haiku doing per-song analysis** (cloud, so the local
model stays free for other work). Three steps:

```bash
# 1. extract candidates (songs WITH lyrics whose sentiment isn't lyrics-sourced) into
#    on-disk batch files. NO --max-chars cap by default: Claude handles long lyrics well
#    (and reliably detects scrape-artifact "lyrics" and infers instead) — that's a
#    strength of the Claude path. Cap only when targeting the small LOCAL model.
node lib/extract-sentiment-targets.mjs --index index-out/current/index.json --dir /tmp/sent-upgrade
#    -> prints "args {"numBatches": N, "dir": "/tmp/sent-upgrade"}"

# 2. run the workflow (Opus orchestrates; N Haiku agents each read one batch file from
#    DISK and WRITE /tmp/sent-upgrade/out/out-NNN.jsonl). Lyrics stay on disk, off the
#    workflow args/return channel, so the orchestration payload stays tiny.
#    Workflow({ name: "sentiment-upgrade", args: { numBatches: N, dir: "/tmp/sent-upgrade" } })

# 3. fold the results back into the index in place (idempotent; touches only song-level
#    sentiment fields — never album status/tracks; honors source:"lyrics" only when the
#    song still has lyrics):
node lib/apply-sentiment-upgrade.mjs --index index-out/current/index.json --dir /tmp/sent-upgrade
```

**Reusable pattern (Opus-orchestrate + Haiku per-item, disk-batched):** shard the work
to per-batch files on disk → one Haiku `agent()` per batch with a strict `schema` return
→ each agent reads its batch and writes a result JSONL → a small `lib/apply-*.mjs` folds
the result files into the index by stable id. Keep large payloads (lyrics, audio) on disk,
not in `args`/return. Re-run any short batch with a single targeted agent before folding.

## Out-of-band stages & live-index folds (`lib/apply-*.mjs`)

The audio stage and the cover/lyrics/sentiment backfills run AFTER the streaming merge and
are folded into the already-built `index.json` **in place**, keyed by stable `alb_*/sng_*`
ids. Every fold is **idempotent** and obeys the same **metadata-ownership rule** as the
merge: it only writes its own fields and never downgrades an album's matched status or
wipes tracks.

| fold | input | writes |
| --- | --- | --- |
| `apply-audio.mjs` | `audio.jsonl` | `album.audioTracks` (+ per-song `bpm`/`key`/`camelot`/`pointer.startMs/endMs`) |
| `apply-backfill.mjs` | `covers-backfill.jsonl`, `lyrics-backfill.jsonl` | `album.coverArt` (if missing), `song.lyrics` (if missing) |
| `apply-sentiment-upgrade.mjs` | `<dir>/out/*.jsonl` | `song.sentimentKeywords` + `sentimentSource` |

### 5. Audio stage — `audio/audio_index.py` + `scripts/audio-index.sh`

Per-song **BPM / key / Camelot / start–end timestamps** from the raw audio. It's Python
(librosa), run OUT OF BAND (no audio in the app), in **Docker** for a reproducible linux
toolchain. For each album it copies the source file to scratch, **silence-segments** it
into tracks (`librosa.effects.split`, defaults top_db 24 / min_gap 0.8s / min_track 40s),
runs a windowed (~90s) **BPM** (`librosa.beat.beat_track`) + **key** (Krumhansl-Schmuckler
chroma → Camelot wheel) per segment, then **deletes the copied file + segments in a
`finally`** so scratch never grows. Each album is analyzed in an isolated subprocess with a
timeout; the macOS arm64 librosa wheel segfaults under in-process concurrency, so we get
parallelism by running **multiple single-concurrency Docker containers**, sharded round-robin.

```bash
# build once, then run AUDIO_CONC sharded containers over a mounted source dir:
docker build -t pocketdj-audio .claude/skills/analog-indexer/audio
AUDIO_CONC=3 SRC=/Volumes/RipBurnMix scripts/audio-index.sh
#   -> index-out/shards-pw/audio-parts/audio.shard-K.jsonl, merged to audio.jsonl
node lib/apply-audio.mjs --index index-out/current/index.json   # fold BPM/key into the index
```

Output records are `{albumId, originalFilename, durationSec, segments:[{i,startMs,endMs,
durationMs,bpm,key,camelot,keyStrength}], ok}`. The album→file link is `album.pointer.originalFilename`.

## Outputs

- `index-out/full/index.json` — canonical index (see `docs/SCHEMA.md`,
  `schema/index.schema.json`, `docs/LOADER_CONTRACT.md`). Each album carries an
  `indexing` map = its per-stage manifest (what each sub-indexer did).
- `index-out/full/coverage-report.json` — match/lyrics/sentiment scorecard.
- `index-out/full/run-log.json` — per-album provenance. The proof-of-verification artifact.

The app auto-seeds from `public/current-index.json`, so the shipped catalog is this
merged `index.json` copied there (see the `publish-s3` skill).

## Resuming / re-indexing

- Every stage is resumable: re-run the exact same command — it reads its `--out` file
  and skips done candidateIndexes (`resuming N done, M remaining`).
- Content-derived ids (`alb_*/sng_*`) make merge idempotent.
- Selective re-index: drop/reset a stage's records and re-run that stage only (the
  streaming files; or `pipeline.mjs redo <stage> [--failed]` in manifest-file mode).
- `scripts/run-pipeline.sh` re-invokes each resumable worker in a loop until the upstream
  is done AND the stage has caught up (writes a `.done` marker).

## Files

- `lib/parser.js` `lib/normalize.js` `lib/itunes.js` `lib/ids.js` `lib/assemble.js`
  `lib/merge.js` `lib/batching.js` — pure helpers (Node, unit-testable; `lib/parser.test.mjs`
  is run via `npm run indexer:parser-test`, and is also picked up by `npm test`).
- `lib/manifest.mjs` — `buildFromStages` overlay + stage stamping + status report.
- `lib/pipeline.mjs` — `status` / `import-metadata` / `run` / `redo` / `merge`.
- `lib/cli.mjs` — parse / plan / merge entry points.
- `lib/enrich-playwright.mjs` `lib/enrich-google.mjs` `lib/enrich-lyrics.mjs`
  `lib/enrich-sentiment.mjs` `lib/synth-singles.mjs` — the sub-indexers.
- `lib/sentiment-todo.mjs` `lib/sentiment-claude-merge.mjs` — the Claude sentiment path.
- `lib/build-sentiment.mjs` `lib/build-run.mjs` — Workflow script builders.
- `workflow/sentiment.workflow.js` `workflow/index-vinyl.workflow.js` — Workflow templates.
- `scripts/run-pipeline.sh` `scripts/run-backfill.sh` `scripts/finish-pipeline.sh` —
  streaming runners (in the repo `scripts/` dir, not under the skill).
- `prompts/` — human-readable copies of the agent prompts.
- `schema/` — index schema + agent output schemas.
