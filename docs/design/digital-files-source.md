# Digital Files Source + Indexer — Design

**Status:** Proposed (design review)
**Scope of this round:** Index the on-disk root `/Volumes/RipBurnMix 1/Pocket DJ`
into a new catalog source **"My Digital"**, upload audio + art + analysis to S3,
run every analysis indexer (BPM/key, beat grid, stems), and wire the native app so
the source can be **enabled and used exactly like any other** — browse, stream
(directly from S3, no rip), burn, mix, add to playlists/pockets/setlists.
**Out of scope this round:** the in-app "add a digital source → pick S3 config or
local folder → app calls the indexer" trigger UI (future round; the design leaves
that seam clean).

---

## 1. The load-bearing insight

Two independent artifacts make a song work, and they're already decoupled:

| Artifact | Lives at | Gives the song… |
|---|---|---|
| **Catalog `index.json`** | catalog CloudFront (`digital-index.json`) | **browsability** — it appears in the app, tagged to source "My Digital" |
| **Rips `manifest.json` entry** (`key` → S3 object) | rips bucket (`rips/manifest.json`) | **playability** — stream + burn with **zero rip step** |

Everything else — Apple Music streaming, the rip server, mix, beat-pulse — keys off
fields that are *optional enrichments* layered on top of those two. Concretely:

- `BurnStore.burn()` gates only on `rips.cachedURL(songId)` → resolves
  `manifest[songId].key` to an S3 URL. Present ⇒ download from S3, **never rips**.
- `RipsStore.ensureURL()` returns `cachedURL` immediately when the manifest has the
  key — **no rip server needed to stream**.
- `PlaybackCoordinator.providers(for:)` only tries Apple Music when the song's
  source == `Config.appleMusicSourceName`. Ours is "My Digital" ⇒ it goes straight
  to the rip provider ⇒ which short-circuits to the S3 URL.

**So the indexer's whole job is: produce the catalog index + the manifest entries,
and upload the audio.** The app then "just works" with no playback-path changes.

---

## 2. New source identity

- `sourceName` = **`My Digital`** (manifest field; drives source tagging + the ID
  namespace). This is **frozen** — changing it later changes every album/song ID.
- Index published to the catalog CloudFront as **`digital-index.json`**
  (mirrors `apple-music-index.json`).
- App config additions (`Config.swift`):
  - `digitalIndexURL = catalogBase/digital-index.json`
  - `digitalSourceName = "My Digital"`
- Settings gets a one-tap **"Load My Digital"** button mirroring "Load Apple Music"
  (`loadMyDigital()` adds/enables a `SourceConfig{name:"My Digital", url:digitalIndexURL}`).
  This is the minimal first-class "enable the source" affordance; the generic
  per-source S3/local config UI is the future round.

---

## 3. The indexer (`scripts/index-digital-files.mjs`)

Reuses the analog-indexer lib (`ids.js`, `normalize.js`, streaming-manifest staging,
S3 helpers). Designed around an input *mode* so it composes with the future trigger:

```
indexDigital({ mode: 'local-root', root, sourceName: 'My Digital' })   // this round
indexDigital({ mode: 's3', bucket, prefix, accessKeyId, secretKey })   // future
indexDigital({ mode: 'stream', file, artist, album })                  // future (app streams files in)
```

### 3.1 Directory walk → candidates

Rules (validated against the real volume):

- **Top-level folder** = artist.
- **Sub-folder of an artist** = album.
- **Bare audio file directly in an artist folder** = single (one-track album,
  album name = track title).
- **Bare audio file in the root** = single, **artist = "Unknown"**, title = filename.
- **Only audio files *directly* in an album folder are tracks.** Deeper nesting
  (e.g. `Little Boots/1 No Pressure/Hat intro Project/Samples/…` Ableton project
  scaffolding) is **ignored** — those stray `.wav`s are not tracks.
- **Junk filter** — only known audio/image extensions are considered. Skip
  `.asd .alc .als .m3u .cue .cfg .log .DS_Store` etc.
  - Audio: `mp3 m4a wav aif aiff flac alac aac ogg opus wma` (present: mp3, wav,
    m4a, aif, flac).
  - Image: `jpg jpeg png webp gif heic` (present: jpg, png).
- **Multi-disc** — `[Disc 1]` / `[Disc 2]` sibling folders → **see decision D3**
  (merge to one album w/ disc numbers vs. separate albums).

### 3.2 Metadata (per track)

Read ID3 via **`ffprobe`** (no new dependency — already used). Fields:
`title, artist, album, track (TRCK → trackNumber + disc), date→year, genre`.

Fallback ladder when a tag is missing:
- **title** ← ID3 title → cleaned filename (strip leading `NN ` / `N-NN ` track prefix).
- **artist** ← ID3 artist → **artist folder name** (root-level bare files → `Unknown`).
- **album** ← ID3 album → **album folder name** → for singles, the track title.
- **trackNumber** ← ID3 `TRCK` → leading number in filename → file order in folder.

All of this is user-editable in the app afterward (existing local-edit overlay).

### 3.3 Transcode → 256 kbps MP3

Every audio file (mp3/wav/m4a/aif/flac) → **256k MP3** via the established invocation:

```
ffmpeg -y -i <src> -map 0:a:0 -codec:a libmp3lame -b:a 256k \
  -metadata title=… -metadata artist=… -metadata album=… -id3v2_version 3 <out>
```

Source bitrates vary (some mp3s are 192k) so this is a real normalize, not a copy.
Output lands at the deterministic rips key `rips/<songId>.mp3`.

### 3.4 Album art

Per the existing vinyl convention (`/art/<albumId>.jpg`, 256px JPEG on the catalog
CloudFront):

- **Primary:** extract embedded ID3 cover from the album's first tagged track
  (`ffmpeg -i track -an -map 0:v:0 …`). Most albums here carry embedded art and have
  no loose image file (e.g. `BANKS/III`).
- **Override:** a loose image file in the album folder wins if present.
- Scale longest edge → 256px JPEG (the `mirror-art.mjs` ffmpeg recipe), upload to
  catalog bucket `art/<albumId>.jpg`, set `coverArt: "/art/<albumId>.jpg"` on the
  album. Native `Config.artURL` + web `coverArtSources` both resolve it.

### 3.5 IDs (stable / idempotent)

```
ns       = "digital|My Digital"
albumId  = "alb_" + sha1(`${ns}|${normalize(artist)}|${normalize(album)}`)[:12]
songId   = "sng_" + sha1(`${albumId}|${disc||1}|${track||0}`)[:12]
```

Same inputs → same IDs across re-runs ⇒ re-indexing is **upsert by id** (idempotent).
Singles with no track number hash on a stable per-file key (album folder + filename)
so they don't collide.

### 3.6 Stages (resumable, streaming-manifest pattern)

Each stage appends NDJSON and **skips already-done work** (presence check), so a
re-run or a crash resumes cheaply:

1. **walk** → `candidates.jsonl` (artist/album/disc/track/path/fileType)
2. **transcode + id3** → local `*.mp3` + `id3.jsonl` (skip if mp3 already present & fresh)
3. **art** → `art/<albumId>.jpg` (skip if uploaded)
4. **upload-audio** → `s3://…/rips/<songId>.mp3` (skip if object exists & same size)
5. **analyze** → BPM/key + beat grid + waveform (skip if `analysisVersion` current)
6. **stems** → Demucs 4 stems (skip if `stemVersion` current) — *long; see D4*
7. **assemble** → `digital-index.json` + a `manifest-fragment.json` of rips entries

---

## 4. S3 layout

**Catalog bucket** (`pocketdj-dev-web-011183829623`, behind dev CloudFront):
```
digital-index.json                 # the catalog (albums/songs/playlists)
art/<albumId>.jpg                  # 256px album art
```

**Rips bucket** (`pocketdj-rips-011183829623`, public):
```
rips/<songId>.mp3                  # 256k audio (source:"digital", startMs:null)
rips/analysis/<songId>.json        # beat-grid sidecar (beatsMs/downbeatsMs/…)
rips/stems/<songId>/{vocals,drums,bass,other}.mp3
rips/manifest.json                 # SHARED — we MERGE our entries in (see §5)
```

Each manifest entry we add:
```json
"sng_…": { "key":"rips/sng_….mp3", "ext":"mp3", "source":"digital",
           "albumId":"alb_…", "startMs":null, "durationMs":<ms>,
           "bytes":<n>, "rippedAt":<epoch-ms>,
           "bpm":…, "musicalKey":…, "camelot":…, "analyzed":true,
           "beatGridBpm":…, "firstDownbeatMs":…, "steady":…,
           "beatgrid":"rips/analysis/sng_….json", "analysisVersion":1,
           "stems":{…}, "stemVersion":1, "stemModel":"htdemucs", "stemFormat":"mp3" }
```

---

## 5. Manifest merge (the one real hazard)

`rips/manifest.json` is **shared and live** — the rip-server holds it in memory and
**rewrites the whole file** on every rip/analysis save. If the indexer edits the S3
object directly while the server is running, the server's next save **silently
overwrites** our digital entries (lost update). Two safe paths — **decision D1**:

- **D1-A (recommended): route writes through the rip-server.** Add
  `POST /ingest-digital` accepting a batch of `{songId, entry}` → merges into the
  authoritative in-memory manifest → `saveManifest()`. Mirrors the existing
  `POST /analysis` merge pattern, is crash-safe, and **composes with the future
  app-driven trigger** (same endpoint). Requires the server reachable (Tailscale)
  during ingest.
- **D1-B: one-shot offline merge.** Quiesce the rip-server, indexer reads
  `rips/manifest.json`, merges the fragment, writes it back, restarts the server.
  Simpler for a single batch, but doesn't compose with the future flow and needs the
  server stopped.

The native app reads the merged `rips/manifest.json` via `RipsStore.refreshManifest()`,
so once merged, every digital song is instantly stream/burn-ready.

---

## 6. Analysis pipeline

Run **locally on the transcoded MP3s** (this Mac has `ffmpeg` + librosa Docker + MPS
Demucs), reusing `scripts/lib/audio-analyze.mjs` and `scripts/lib/audio-stem.mjs` —
no need to round-trip through S3:

- **BPM / key / camelot** — `audio-analyze.mjs {withKey:true}` (librosa, per single
  file) → manifest `bpm/musicalKey/camelot` + index `song.bpm/key/camelot`.
- **Beat grid** — `{withBeatgrid:true}` → `rips/analysis/<songId>.json` sidecar +
  manifest scalars (`beatGridBpm/firstDownbeatMs/steady/analysisVersion`).
- **Waveform** — `{withWaveform:true}` → `rips/waveforms/<songId>.png` (bonus, free).
- **Stems** — `audio-stem.mjs` (Demucs htdemucs, MPS) → `rips/stems/<songId>/…` +
  manifest `stems/stemVersion`. **Heavy** (minutes/song × hundreds of songs).

All stages are idempotent (skip when the version stamp is current), matching how
`/backfill-beatgrids` and `/backfill-stems` already behave.

---

## 7. App wiring (small, native)

Everything playback-side is already generic. The only app changes:

1. `Config.swift` — add `digitalIndexURL` + `digitalSourceName`.
2. `SettingsStore.swift` — `loadMyDigital()` (mirror `loadAppleMusic()`), idempotent.
3. `SettingsView.swift` — a "Load My Digital" button (a11y `settings-load-my-digital`).
4. (Optional polish) hide the **Rip** action for a collection when every song is
   already in the manifest (cosmetic; `burn()` already skips ripping them).

No changes to `BurnStore`, `RipsStore`, `PlaybackCoordinator`, `SetlistPlayer`,
`MixEngine`, or `PlayerEngine` — pre-ripped digital songs traverse the existing paths.

---

## 8. Idempotency & re-run semantics

- Stable content-derived IDs ⇒ re-running upserts, never duplicates.
- Every stage skips completed work (mp3 present, S3 object exists, version stamp
  current) — re-burning a setlist re-pulls only what changed, same as stems today.
- `rippedAt` set to the ingest time so `BurnStore.isFresh()` can detect updates.

---

## 9. Future-round seam (north star)

The end state: in-app, the user adds a digital source and either
- **picks a local folder** → app idempotently *streams each file* to the indexer
  (`mode:'stream'`), or
- **enters S3 config** (bucket/prefix/access/secret, stored in `SourceConfig`
  optional fields) → app hands it to the indexer (`mode:'s3'`) which *pulls* the files.

This round implements `mode:'local-root'` run from the CLI; the `POST /ingest-digital`
endpoint (D1-A) and the mode-based indexer interface are the seams that the future
trigger plugs into without rework.

---

## 9b. Known limitation — positional ids for untagged tracks

`songId = sha1(albumId | disc | track)`. A track's `track` number comes from its ID3 `TRCK`
tag, else a leading filename number (`01 …`, `1-05 …`), else its **positional** index within the
(album, disc) after a deterministic sort. For the ~124 library tracks that have *neither* a tag
nor a numbered filename (beat-tape cuts with descriptive names), the id is therefore positional:
**stable for a fixed file set** (the sort is deterministic), but it shifts if files are added/
removed from that album folder between indexings. That's fine for the re-burn workflow (same
files) — and the `||` guard means a literal `TRCK 0` never produces a `track:0` id. Adversarial
review flagged the add/remove-a-sibling case (HIGH); a content-stable id (hash the audio bytes or
the filename) is the correct fix but would re-key those 124 already-uploaded songs, so it's
deferred to a clean full re-index (a **future migration**, §11) rather than churned in-flight.

## 10. Decisions (resolved 2026-06-30)

- **D1 — manifest write path → rip-server `/ingest-digital` endpoint.** The
  authoritative in-memory manifest merges + saves; same endpoint the future
  app-driven trigger will call. No direct S3 manifest edits.
- **D2 — rollout → pilot BANKS (~28 tracks, 2 albums) end-to-end first**, validate in
  the app, then run the full ~600-file library.
- **D3 — multi-disc → merge `[Disc N]` siblings into one album** carrying disc numbers
  on the tracks (so the `songId = sha1(albumId|disc|track)` stays unique).
- **D4 — stems → ship browse/stream/burn/bpm/key/beatgrid first** (source usable within
  ~the hour), then run Demucs stems as a resumable background pass that unlocks stem
  decks in Mix as each completes.

---

## 11. Future migrations

- **Content-stable ids for untagged tracks (§9b).** Re-key the ~124 positional-id tracks to a
  content-derived id (audio-byte hash or `sha1(albumId|disc|f:filename)`) on a clean full
  re-index, so re-indexing survives file-set changes in those album folders. Requires re-uploading
  those songs + pruning the orphaned `rips/<oldid>.mp3` + manifest entries + analysis sidecars.
- **In-app "add digital source" trigger (§9).** The app calls the indexer with a local folder
  (idempotently streaming files) or an S3 config (bucket/prefix/creds in `SourceConfig` optional
  fields). The `mode:'local-root'|'s3'|'stream'` interface + `POST /ingest-digital` are the seams.
- **iTunes art fallback.** 16/43 albums have no embedded/loose cover; an optional iTunes-Search
  artwork lookup (like the vinyl `mirror-art` path) could fill those.
