# Chapter 2 — Ingest & Enrichment: diverse sources → one catalog

> Part of the [PocketDJ Architecture Book](../ARCHITECTURE.md). Prereq:
> [Chapter 1 — Foundations](./01-foundations.md). This chapter is the **"from
> diverse musical sources"** pillar of the goal: how raw, messy inputs become one
> uniform, enriched, mixable catalog.

Each section is **Why → What → How (worked example)**, with an ASCII diagram whose
boxes and arrows are explained in the prose beneath it.

---

## 1. Filesystem — analog audio sources (the ground truth)

**Why.** The vinyl crate is digitized as raw recordings on the iMac. These are the
ground truth for two things the catalog can't fabricate: the actual audio to
rip/burn, and the BPM/key/segment analysis. The filename is the *join key* between a
catalog album and its bytes.

**What.** A directory of recordings (default `~/Downloads`, in practice
`/Volumes/RipBurnMix`) named `ArtistNameAlbumNameRaw.<ext>` (e.g.
`ABBAGreatestHitsRaw.mp3`). The `Raw` marker is how the parser recognizes a vinyl
line. The album→file link is `pointer.originalFilename`; per-song offsets into a
multi-track side are `pointer.startMs`/`endMs`, written by the audio stage.

```
   /Volumes/RipBurnMix/ABBAGreatestHitsRaw.mp3   (one album side, many tracks)
        │ parser strips "Raw" → artist="ABBA", album="Greatest Hits"
        ▼
   IndexAlbum.pointer.originalFilename = "ABBAGreatestHitsRaw.mp3"
        │                                   ▲
        │ audio stage (apply-audio.mjs)     │ consumers resolve back to the file:
        ▼                                   │
   IndexSong.pointer.{startMs,endMs}  ──────┴── rip-server  (analog path, Ch. 5)
   per detected segment                          burn-setlist (ffmpeg -ss/-t carve)
```

**Reading the diagram.** A single file *is* one album side holding several tracks
back-to-back. The analog-indexer **parser** reads the filename, strips `Raw`, and
splits artist/album, storing the original name as `pointer.originalFilename`. The
**audio stage** silence-segments the recording and writes each segment's absolute
offsets to the song's `pointer.startMs`/`endMs`. Two consumers resolve back via
`originalFilename`: the **rip server's analog path** and the **burn-setlist** skill
(`ffmpeg -ss <start> -t <duration>`). Segmentation is **independent of the metadata
tracklist** — a song's analyzed segment count may differ from its metadata track
count by design.

**How (worked example): burning a setlist track.** A CSV row carries
`Song ID = sng_8c1d…`. `burn-setlist` looks it up, reads `pointer.filename`,
`startMs=132000`, `endMs=318000`, then `ffmpeg -ss 132 -t 186 -i <rip> -c:a
libmp3lame -b:a 320k out.mp3` + a `.txt` sidecar (BPM · Camelot · sentiment · album).

---

## 2. Apple Music `Library.xml` — the digital source

**Why.** A second, *digital* source — the user's whole Apple Music library —
multiplies the catalog (≈12,220 albums / 92,865 songs vs vinyl's 1,361 / 12,525)
with real genre/year/track metadata and the **Persistent IDs** the rip server needs
to find a track in Music.app.

**What.** Two producers and two consumers:
- **Producer A** — the user exports Music ▸ File ▸ Library ▸ Export Library… to
  `~/Downloads/Library.xml`.
- **Producer B** — `scripts/dump-apple-music-library.mjs` drives Music via AppleScript
  to *generate* an iTunes-style plist + a fast TSV (`index-out/apple-music-library.{xml,tsv}`)
  headlessly, incremental by `date added`.
- **Consumer 1** — the indexer → `apple-music-index.json`.
- **Consumer 2** — the `rip` skill / `rip-one.mjs` → **Persistent ID** for playback.

```
   Music.app library
     │  user Export… ──────────────▶ ~/Downloads/Library.xml ──┐
     │                                                          ▼
     │  dump-apple-music-library.mjs                 apple-music-indexer
     │  (AppleScript, headless,         ┌──────────  scripts/index-apple-music.mjs
     ▼  incremental by Date Added)      │            (line-by-line plist parse)
   index-out/apple-music-library.xml ───┘                      │
   index-out/apple-music-library.tsv ──▶ rip skill            ▼
        (Persistent ID lookup)            (play exact track)  apple-music-index.json
                                                              sng_=sha1(digital|name|persistentID)
```

**Reading the diagram.** The live **Music.app library** becomes files two ways. The
manual **Export…** writes canonical `~/Downloads/Library.xml`. In parallel,
`dump-apple-music-library.mjs` drives Music via **AppleScript** (Automation
permission only) to write an equivalent plist + fast TSV under `index-out/`, fetching
only tracks newer than the last run for incrementals. The **apple-music-indexer**
parses a plist **line-by-line** (memory bounded by album count, not the 160 MB file),
emitting `apple-music-index.json` with **source-namespaced ids** so a digital album
owned *also* on vinyl never collides. The **rip skill** uses the TSV/XML to resolve a
PocketDJ song to its Persistent ID and `play` the exact track.

**How (worked example): incremental re-index.** `node scripts/index-apple-music.mjs
--xml ~/Downloads/Library.xml --out index-out/apple-music/index.json` reads
`state.json`'s `lastDateAdded`, emits only tracks since (plus albums + playlists),
advances the state, conforms to `src/types/index-json.ts`, then `cp →
public/apple-music-index.json` + `deploy.sh`.

---

## 3. AppleScript / Shortcuts "API" — capturing what can't be copied

**Why.** Apple Music has no "give me the bytes" API, and most of the library
streams. The only capture path is to **play it and record the output in real time**,
driven via AppleScript (playback) + macOS Shortcuts (the recorder), using
**Automation** permission only — never Accessibility.

**What.** The `rip` skill (`.claude/skills/rip/rip.mjs`) and the rip server's digital
worker (`scripts/rip-one.mjs`):
- **AppleScript ▸ Music** — `play (… whose persistent ID is …)`, name+artist
  fallback; poll `player position` for end.
- **Shortcuts ▸ Audio Hijack** — `shortcuts run "Rip Start"` / `"Rip Stop"` triggers
  AH's "Run/Stop Session" (external `.ahcommand` files can't control sessions; only
  the Shortcuts action can from the CLI).

```
   PocketDJ Song ID → (index) canonical artist/title → (Library.xml) Persistent ID
        │
        ▼
   shortcuts run "Rip Start"  ──▶  Audio Hijack records Music output (~/Music/Audio Hijack)
        ▼
   osascript: play track (persistent ID)  ──▶  Music.app plays it; poll until end (+tail)
        ▼
   shortcuts run "Rip Stop"   ──▶  newest recording → ffmpeg -c copy remux + tag
        ▼
   NN - Artist - Title.<ext>   (+ rip-manifest.json)
```

**Reading the diagram.** From a **Song ID**, resolve canonical artist/title via the
index, then the **Persistent ID** via `Library.xml`/`.tsv`. `"Rip Start"` tells
**Audio Hijack** to record Music's output to its Recorder folder. `osascript` then
`play`s the exact track by Persistent ID; the skill **polls** `player position` until
end (plus a tail). `"Rip Stop"` ends recording; the newest file is moved out,
`ffmpeg -c copy` remuxes/tags it, named `NN - Artist - Title.<ext>`, with a per-run
`rip-manifest.json`. Chapter 5 shows how the rip server wraps this into its job
state machine.

---

## 4. Analog indexing — vinyl files → catalog (5 stages)

**Why.** Turn `data/Vinyl.md` (a list of `*Raw` filenames) into a fully enriched
`current-index.json`: metadata, lyrics, sentiment, audio analysis, and self-hosted
art — so the crate is browsable, filterable, and mixable.

**What.** The analog-indexer (`.claude/skills/analog-indexer`) runs five resumable,
manifest-driven stages, each streaming a JSONL shard, then merges + folds them.

```
 data/Vinyl.md (ArtistAlbumRaw lines) ── cli.mjs parse
     ▼
 [1] enrich (metadata)   Discogs API + Wikipedia (headless Playwright/Chromium)
     │   ├─ backfill: Claude WebSearch agents → web.jsonl  (unmatched albums)
     │   └─ synth-singles: fold leftover 12" singles
     ▼
 [2] lyrics              enrich-lyrics.mjs (Genius → AZLyrics), reject >20k-char dumps
     ▼
 [3] sentiment           local Gemma (LM Studio :1234)  OR  Claude agents
     ▼
   merge (pipeline.mjs)  → index-out/full/index.json
     ▼
 [4] audio               audio_index.py in Docker (librosa): silence-split +
     │                   windowed BPM + Krumhansl key → Camelot  → apply-audio.mjs
     ▼
 [5] mirror-art          thumbnail covers → /art/<albumId>.jpg, rewrite coverArtSources
     ▼
 public/current-index.json  ── deploy.sh ──▶ S3 web bucket / CloudFront (Ch. 7)
```

**Reading the diagram.** `cli.mjs parse` splits each `*Raw` line into stubs. **[1]
enrich** queries the **Discogs API** (primary) and **Wikipedia** (fallback) from a
real **Chromium** page; unmatched albums are recovered by **Claude WebSearch backfill
agents** (→ `web.jsonl`), and leftover 12" singles are folded by `synth-singles.mjs`.
**[2] lyrics** scrapes Genius then AZLyrics, rejecting page-dumps over 20k chars (the
robustness fix). **[3] sentiment** derives mood keywords from a **local Gemma** model
(LM Studio `127.0.0.1:1234`) or **Claude agents**. `pipeline.mjs merge` assembles all
shards. **[4] audio** runs `audio_index.py` in the **`pocketdj-audio` Docker image**
(librosa): silence-segment (`librosa.effects.split`), windowed BPM (`beat_track`) +
Krumhansl-Schmuckler key → Camelot per segment; `apply-audio.mjs` folds segments onto
album `audioTracks` + song `pointer.startMs/endMs` (note: macOS arm64 librosa
segfaults under in-process concurrency → run several single-concurrency containers).
**[5] mirror-art** thumbnails covers + rewrites `coverArtSources`. The result is
copied to `public/current-index.json` and deployed.

All fold steps (`apply-*.mjs`, `dedup-tracks`, `renumber-tracks`, `reattach-orphans`)
are **idempotent and keyed by `alb_*/sng_*` ids**, so re-runs never duplicate or
downgrade matched data.

---

## 5. Audio analysis + art mirroring — the two write-back side-channels

**Why.** BPM/key/Camelot and self-hosted art are computed *out of band* and folded
back into the catalog or the rips manifest so they become first-class, filterable,
offline-durable data.

```
                       ┌──────────────── BPM / KEY / CAMELOT ───────────────┐
 raw vinyl rip ──▶ analog-indexer audio stage (Docker librosa) ──▶ index.json audioTracks
 ripped mp3   ──▶ rip-server enqueueAnalysis → audio-analyze.mjs ──▶ rips/manifest.json
                  (Docker librosa + ffmpeg waveform)                  {bpm,musicalKey,camelot,waveform}
                       └────────────────────────┬───────────────────┘
                                                ▼ client refreshManifest()
                              applyAnalysisToCatalog(): FILL gaps only (never clobber)
                                                ▼
                                         IndexedDB song bpm/key/camelot

 remote cover URL ──▶ mirror-art.mjs thumbnail ──▶ /art/<albumId>.jpg (S3) + coverArtSources
                                                ▼ client prefers cdn/cors source
                                         fetch+thumbnail → IndexedDB blob (offline)
```

**Reading the diagram.** Two sources of BPM/key/Camelot: the **analog-indexer audio
stage** (at index time → `audioTracks` in `index.json`) and the **rip server**
post-hoc (`enqueueAnalysis()` → `audio-analyze.mjs`, same Docker/librosa analyzer +
an `ffmpeg showwavespic` waveform → `rips/manifest.json`). The client's
`refreshManifest()` runs `applyAnalysisToCatalog()`, which **fills gaps only** —
never overwriting an existing value with null — so accurate analog values are kept and
only digital (null) songs get filled, then everything is filterable/sortable/on the
star map. Separately, `mirror-art.mjs` thumbnails each remote cover to
`/art/<albumId>.jpg` and rewrites `coverArtSources`; the client prefers the cdn/cors
source, fetches it same-origin, and caches the blob in IndexedDB for offline use.

---

## 6. Beat-grid & stem analysis — two more rips-manifest side-channels

**Why.** The Mix engine (Ch. 4 §7) needs two enrichments §5's analysis doesn't produce: a
**measured beat grid** (a real downbeat phase + a tempo measured on the *exact* file that
plays, for beat-matching) and **isolated stems** (vocals/drums/bass/other, for stem decks).
Both are computed **out of band on the iMac** and folded into the **rips manifest** (not the
catalog index), exactly like the post-rip bpm/key analysis — so they're durable, public, and
client-readable without re-deriving anything on the phone.

```
                       ┌─────────────── BEAT GRID (librosa downbeat) ───────────────┐
 ripped mp3 / cut ──▶ rip-server POST /backfill-beatgrids → audio-analyze.mjs        │
                       (analyzeAudio withBeatgrid:true)  ──▶ manifest {beatGridBpm,   │
                                                              firstDownbeatMs,steady,…}│
                       └──────────────────────────┬─────────────────────────────────┘
                       ┌─────────────── STEMS (Demucs htdemucs v4) ─────────────────┐
 ripped mp3 / cut ──▶ rip-server POST /stemify (per-song) · /backfill-stems          │
                       audio-stem.mjs → Demucs (native MPS · Docker-CPU fallback)     │
                       → 4× mp3 256k → rips/stems/<songId>/<stem>.mp3 (PUBLIC)         │
                       └──────────────────────────┴──▶ manifest {stems,stemVersion,…} ┘
                                                ▼ client refreshManifest()
                              Mix engine: Sync rides beatGridBpm ; stem decks load stems
```

**Reading the diagram.** Both passes are **rip-server endpoints** (Ch. 5 §15), not separate
skills — the **beat-grid** stage re-runs the same librosa analyzer (`scripts/lib/audio-analyze.mjs`,
`analyzeAudio(… withBeatgrid:true)`) to get a **downbeat grid** and writes `beatGridBpm`/
`firstDownbeatMs`/`steady`/… onto the manifest entry; the **stem** stage shells to **Demucs**
(`htdemucs`, v4, via `scripts/lib/audio-stem.mjs` + the Docker/Python assets under
`.claude/skills/analog-indexer/stems/` — `Dockerfile` + `separate-one.py`, a sibling of the
librosa `audio/` stage) to split each song into **four 256k-mp3 stems** uploaded to the
**public** `rips/stems/<songId>/` prefix. Both source the **per-song** audio (a digital song's
mp3, an analog song's per-song **cut** — never the shared album side) and both have **`/backfill-`**
endpoints to sweep the whole corpus retroactively. The full pipelines (queues, runtimes,
manifest fields, idempotency) live in [Ch. 5 §15](./05-playback-and-rip-on-demand.md#15-stems-end-to-end--server-stemify-offline-stem-store-and-stem-audition);
the *data shape* they write is [Ch. 3 §4.3](./03-catalog-and-data-model.md#43-the-rips-manifest-beat-grid--stem-fields).

---

## Where this feeds

The output of this chapter is two JSON documents (`current-index.json`,
`apple-music-index.json`) conforming to one shape. That shape is
[Chapter 3 — Catalog & Data Model](./03-catalog-and-data-model.md).

## Next

→ [Chapter 3 — Catalog & Data Model](./03-catalog-and-data-model.md)
