# Chapter 3 — Catalog & Data Model: the one shape everything speaks

> Part of the [PocketDJ Architecture Book](../ARCHITECTURE.md). Prereqs:
> [Ch. 1 Foundations](./01-foundations.md), [Ch. 2 Ingest](./02-ingest-and-enrichment.md).
> This chapter is the **"personal catalog"** pillar: the schemas that ingest
> produces, the clients consume, and every other chapter references.

This is a reference chapter — the **source-of-truth files** are authoritative; the
diagrams below summarize their shape.

---

## 1. Index JSON — the indexer↔app contract

**Source of truth:** [`src/types/index-json.ts`](../../src/types/index-json.ts)
(on-disk shape) and [`src/types/model.ts`](../../src/types/model.ts) (internal
model), mirrored by Swift
[`apple/PocketDJ/Models/IndexModels.swift`](../../apple/PocketDJ/Models/IndexModels.swift)
and the JSON Schema `.claude/skills/analog-indexer/schema/index.schema.json`.

```
 IndexJson
  ├─ manifest  { source, generatedAt, schemaVersion, sourceType:'analog'|'digital',
  │              sourceName?, counts, deferredFields[], batches?, cloudReindex? (§1.2) }
  ├─ albums[]  IndexAlbum
  │   ├─ id "alb_"+sha1(normArtist|normAlbum|dupIndex)[:12]
  │   ├─ artist · name · genre? · year? · country?
  │   ├─ coverArt? (remote) · coverArtSources?[{type:'cdn'|'remote',url,cors?}]
  │   ├─ appleMusicId?  (iTunes album collectionId; Discover-album supersede join — §1.1)
  │   ├─ trackList[] → IndexSong.id   · fileType? · pointer? · enrichment?
  │   ├─ audioTracks?[] {trackNumber,startMs,endMs,durationMs,bpm,key,camelot,keyStrength?}
  │   └─ audioDurationSec?
  ├─ songs[]   IndexSong
  │   ├─ id "sng_"+sha1(albumId|track|disc)[:12]   (analog)
  │   ├─ albumId? · artist · name · trackNumber? · year? · length(ms)?
  │   ├─ lyrics? · lyricsStatus? · sentimentKeywords? · sentimentSource? · explicit?
  │   ├─ bpm? · key? · camelot?   (AUDIO stage; null until analyzed; may be CLOUD-overridden §1.2)
  │   ├─ appleMusicId?   (Apple catalog "adam id", e.g. "944459436"; CATALOG stage — §1.1)
  │   ├─ cloudReindex?  {persistentID?, fields[], length?, cloudSongId?}  (CLOUD RE-INDEX prov. — §1.2)
  │   └─ pointer? {fileLocation?,filename?,originalFilename?,disc?,track?,startMs?,endMs?}
  └─ playlists?[] IndexPlaylist { id, name, songIds[] }   (iTunes mirrors)
```

**Reading the diagram.** `IndexJson` is the top-level document: a `manifest`
(provenance + `sourceType` + `counts`; `schemaVersion`'s MAJOR must equal
`INDEX_SCHEMA_MAJOR=1`), parallel `albums`/`songs` arrays, and optional `playlists`
(Apple Music user-playlist mirrors). **Ids are content-derived** (Ch. 1) so re-runs
are idempotent. An album's `trackList` holds ordered `IndexSong.id` refs;
`coverArtSources` is the progressive art list (cdn-first); `audioTracks` is the
independent audio segmentation (count may differ from `trackList`). On the song,
`bpm/key/camelot` come from the AUDIO stage and are **`null` until analyzed** (never
`undefined`, so "pending" stays explicit); `appleMusicId` is the Apple catalog "adam
id" minted by a separate **CATALOG stage** (§1.1) and is **`undefined` until resolved**;
the *album's* `appleMusicId` is the iTunes **`collectionId`** (aggregated from its member
tracks, §1.1) — the join key that lets a real indexed album supersede a provisional
Discover album; `pointer` links back to the raw file (`originalFilename`) and per-segment
offsets.

**Import-time derivation.** When a client imports the index, it maps each
`IndexAlbum`/`IndexSong` to the internal `AlbumItem`/`SongItem` and computes an
**album-level audio rollup** so the star map can group/sort albums without rescanning
tracks:

```
 audioBpm     = MEDIAN(audioTracks[].bpm)          (rounded)
 audioCamelot = MODE(audioTracks[].camelot)        (e.g. "8A")
 audioKey     = MODE(audioTracks[].key)            (e.g. "A minor")
```

`null` when the album has no `audioTracks`, never `undefined` once imported — so "no
audio" stays explicit (mirrors `SongItem.bpm/key`).

### 1.1 The `appleMusicId` CATALOG stage — making Apple Music (Local) songs streamable

**Why a field, and why a separate stage.** Apple Music (Local) songs are minted with
content-derived `sng_…` ids (Ch. 1) that carry **no** Apple catalog reference, so a
client had no way to ask MusicKit to play them — they always fell back to ripping
(Ch. 5 §8). `appleMusicId` carries the Apple catalog **"adam id"** (a bare numeric
string, e.g. `"944459436"`) — empirically the same value MusicKit plays by — so the
native streaming provider can fetch the catalog track directly. It's *deliberately not*
folded into the Apple Music indexer: that indexer
([`scripts/index-apple-music.mjs`](../../scripts/index-apple-music.mjs)) is a fast
(~1.6s), network-free streaming parse of a ~160MB `Library.xml`, whereas resolving
~93k songs against the **public iTunes Search API** is a multi-**day**, network-bound,
rate-limited crawl (~20–60/min). Coupling the two would chain a 1.6s job to a 3-day one.

```
 resolve-apple-music-catalog.mjs            index-apple-music.mjs --catalog-cache
   per-song iTunes Search (trackId)           streaming Library.xml (re)parse
   → score best match (coreTitle, version     → bakes appleMusicId back onto each
     tags) → catalog-cache.ndjson  ───────▶     song from the cache (so a re-index
   {id, storeId|null, collectionId?}            never drops resolved ids; misses
   (resumable, paced, adaptive 403/429          ignored) + album appleMusicId =
    backoff)                                    most-common member collectionId
```

**Source of truth:** [`scripts/resolve-apple-music-catalog.mjs`](../../scripts/resolve-apple-music-catalog.mjs).
It is a standalone, fully **resumable** crawl: a per-song NDJSON cache
(`catalog-cache.ndjson`, keyed by song id, recording hits *and* misses) is appended per
song and the index flushed every `--save-every`; re-running skips anything already in
the cache (`--retry-misses` re-attempts prior misses). Matching is conservative —
diacritic-folded `coreTitle` (parentheticals dropped) plus **version-tag set equality**
(only match a "Remix"/"Live"/"Sped Up" row if both sides carry that marker) — so it
never grabs the wrong take. Pacing uses adaptive 403/429 backoff and retries network
errors forever, built for an unattended multi-day run.

**Why it's still a *candidate*, not gospel.** `appleMusicId` is a `trackId` from a
*search* API; versions/regions can drift, and a track can be removed. So the client
treats it as a **candidate**: the native `AppleMusicProvider.resolve(_:)` verifies it
with a real MusicKit catalog fetch and **degrades to ripping** on a miss (Ch. 5 §8).
The `--catalog-cache` flag on the indexer re-bakes resolved ids onto songs on every
re-index, so the slow crawl's output survives a fast re-parse.

**Albums get a catalog id from the same crawl.** The catalog row that yields a song's
`trackId` also carries the album's **`collectionId`**, so the resolver records it next to
`storeId` at zero extra network cost (a legacy cache hit with a `storeId` but no
`collectionId` is **re-resolved** so the album id gets captured; its `storeId` still
applies meanwhile). [`index-apple-music.mjs`](../../scripts/index-apple-music.mjs)
aggregates the **most-common member `collectionId`** per album into `IndexAlbum.appleMusicId`,
and [`scripts/fold-album-catalogid.mjs`](../../scripts/fold-album-catalogid.mjs) applies the
same mode-per-album stamp as a **fold over an existing index** (dry-run by default,
`--apply` writes) — no full `Library.xml` re-index needed. This is what activates the
Discover-album dedupe for **owned** albums: a provisional Discover album (whose
`appleMusicId` *is* an iTunes `collectionId`) is superseded by the real indexed album
carrying the same id.

### 1.2 The CLOUD RE-INDEX — folding Apple Music truth into the analog catalog

**Why.** The **analog** catalog's audio analysis is weak: the librosa pass on a vinyl
rip is only ~70% right for **length** and ~30% right for **bpm/key** (it segments one
big side into tracks and estimates tempo/key per segment). But for many of those analog
songs the user *also* owns the track in Apple Music, where the library's `Total Time` is
**exact** and a cloud rip (Ch. 5 §8) can produce a clean per-song bpm/key. The cloud is
the source of truth; the re-index folds it back into `current-index.json` **per field,
with cloud precedence**, without touching the rest of the catalog.

**Source of truth:**
[`scripts/reindex-cloud-analysis.mjs`](../../scripts/reindex-cloud-analysis.mjs)
(the durable folder) and the shared matcher
[`scripts/lib/am-match.mjs`](../../scripts/lib/am-match.mjs) (§1.3).

```
 reindex-cloud-analysis.mjs   (inputs: catalog · Library.xml · rips manifest)
   for each ANALOG song:
     findInLibrary(lib, artist, name)  ── EXACT match only (am-match §1.3)
        │ loose/none → leave analog value UNTOUCHED (a wrong overwrite is worse)
        ▼ exact
     ┌─ LENGTH    song.length = lib hit "Total Time" (ms)   ── mass fix, metadata-only
     ├─ BPM/KEY   if a CLOUD manifest entry exists (source:'digital' ∧ analyzed):
     │   /CAMELOT   song.bpm/key/camelot ← entry.bpm/musicalKey/camelot   ── opportunistic
     │             (entry keyed by THIS song's id, else the derived Apple-Music songId
     │              sng_+sha1("digital|Apple Music (Local)|<persistentID>")[:12])
     └─ stamp     song.cloudReindex = {persistentID, fields[], length?, cloudSongId?}
   write SIDE output index-out/reindex/current-index.json + a JSON report
   (NEVER overwrites public/current-index.json; NEVER deploys — owner reviews + applies)
```

**Reading the diagram.** Per analog song the folder asks `am-match.findInLibrary` for an
**exact** Apple Music match (loose/none ⇒ skip, keeping the analog estimate — a wrong
length/key is worse than a fuzzy one). On an exact hit it applies **per-field cloud
precedence**: (1) **length** from the matched library entry's `Total Time` (a metadata-only
mass fix that runs for the whole catalog in minutes, no audio capture); (2) **bpm/key/camelot**
*opportunistically* from a **cloud manifest entry** — `source:'digital' && analyzed === true`
(Ch. 5 §5) — looked up first by the song's **own** id (a "Rip from cloud source" of this very
vinyl track, Ch. 5 §8) and otherwise by the **derived Apple Music songId**
(`sng_+sha1("digital|Apple Music (Local)|<persistentID>")[:12]`, the same namespace
[`index-apple-music.mjs`](../../scripts/index-apple-music.mjs) mints, so a separately-ripped
digital copy's analysis flows in). Every touched song gets a `cloudReindex` provenance stamp
(persistentID + which `fields` changed), and the run is **idempotent**: the output is a pure
function of (catalog, library, manifest) — even the `manifest.cloudReindex` stamp uses the
newest *input* mtime, not wall-clock — so re-running yields a byte-identical
`current-index.json`. It writes to a **side output** (`index-out/reindex/…`) plus a delta
report and **never** mutates `public/current-index.json` or deploys; the owner reviews the
report (which surfaces every >60s length change) and applies the fold by hand. Re-running
later picks up more bpm/key rows as cloud rips accumulate.

### 1.3 Tight matching — `am-match` (the recording must agree)

**Why.** Both the cloud re-index (§1.2) and the cloud-rip routing (Ch. 5 §8) hinge on one
question: *is this analog song the same recording as an Apple Music library entry?* A naive
title match is dangerous — it would collapse a **club mix** onto the **radio edit** and
overwrite the length (e.g. *Living In Danger (For The Big Clubs Only Mix)* 620s vs the
standard 193s) or capture the wrong cut. PocketDJ is built around the user's **own**
collection, so the specific mix/edit/version they own is an intentional choice that must be
preserved.

**Source of truth:** [`scripts/lib/am-match.mjs`](../../scripts/lib/am-match.mjs), shared by
the rip skill (`.claude/skills/rip/rip.mjs`), the rip server, and the re-index (extracted
into one module because `rip.mjs` runs `main()` on import and so can't be imported as-is).

```
 findInLibrary(lib, artist, title) → { hit, match:'exact'|'loose'|'none' }
   na = normArtist(artist)         ct = comparableTitle(title)
   EXACT  na agrees ∧ ct agrees    ── the ONLY class that overwrites / cloud-captures
   loose  paren-stripped subset    ── diagnostics only, NEVER used
   none   no hit

 comparableTitle: keep RECORDING-ALTERING paren groups, drop COSMETIC ones
   RECORDING-ALTERING (must AGREE)  mix·remix·edit·radio·single·instrumental·live·
     acoustic·7"/12" (inch)·dub·extended·club·a cappella·reprise·demo·sped/slowed·
     reverb·karaoke·cover·rework·vip·bootleg·session·take
   COSMETIC (ignored)  remaster·deluxe·anniversary·bonus·mono/stereo·explicit/clean·
     feat./credits·original mix/version·AND a bare/LP/Album "Version" (= standard recording)
```

**Reading the diagram.** `findInLibrary` returns `exact` only when the normalized artist
agrees **and** the *comparable* title agrees. The work is in `comparableTitle`: `normTitle`
strips **all** parentheticals (so a remix would collapse onto the standard recording and
falsely exact-match), so `comparableTitle` instead **keeps** any paren/bracket group that
denotes a different **recording** (a `RECORDING_ALTERING` keyword) and **drops** only purely
**cosmetic** groups (remaster/deluxe/explicit/credits, and — deliberately — a bare/`LP`/`Album`
**"Version"** label, which just denotes the standard album recording, not a different cut).
The exact index is keyed by `normArtist + comparableTitle`, so *"Steelo (LP Version)" ==
"Steelo"* but *"X (Club Mix)" != "X"*. On **any** version-marker disagreement there is **no**
match, so the cloud rip falls back to vinyl and the re-index leaves the analog value
untouched — lower coverage is the accepted price of fidelity. (Tightening the matcher dropped
exact matches ~11% but cut spurious >60s length overwrites 153 → 70, all 70 genuine.) The
same `match === 'exact'` gate is the cloud-eligibility probe in
[Ch. 5 §8](./05-playback-and-rip-on-demand.md#8-stream-first-rip-last--the-native-provider-chain-playbackcoordinator);
the full product rationale lives in
[`docs/design-rip-from-cloud.md`](../design-rip-from-cloud.md).

### 1.4 The STREAMING-LINKS stage — `spotifyUrl` / `youtubeUrl` for sharing

**Why a field, and why a browser.** Sharing a song is only useful if the person
receiving it can actually play it, which means the catalog has to carry a canonical
link per service, not just PocketDJ's own ids. Apple Music links come **free** —
they're derived from `appleMusicId` (§1.1) by
[`scripts/fold-apple-music-links.mjs`](../../scripts/fold-apple-music-links.mjs), no
network at all. Spotify and YouTube expose no usable API here (no credentials; the
YouTube Data API is quota-blocked), so the only route is a **headless Chromium**
(Playwright) driven against each service's public search deep-link, reading the
canonical URL off the best-matching result.

```
 resolve-streaming-links.mjs                 fold-streaming-links.mjs
   per-song headless search                    non-null-only stamp into public/*.json
   spotify: /search/<q>  → /track/<id>         → spotifyUrl / youtubeUrl per song
   youtube: /search?q=   → /watch?v=<id>       (a null NEVER erases an existing link)
   → links-cache.ndjson  ──────────────────▶
   {id, spotifyUrl|null, youtubeUrl|null,
    spotifyMatch{title,artist,score}, …}       backfill-streaming-links.mjs
   (resumable; hits AND misses cached)           supervises BULK crawls of the above
```

**Matching is deliberately strict.** The resolver reuses the same
`normalize()`/`coreTitle()`/`versionTags()` discipline as the Apple Music crawl (§1.3):
a remix/live/sped-up row is never matched to a library track that lacks the marker.
Below `--min-score` it records a **per-service null** rather than a guess — a wrong
"Share on Spotify" link is worse than no link. The cache
(`~/.pocketdj/streaming-links/links-cache.ndjson`) is keyed by song id and records
**hits and misses**, so a re-run skips anything already decided; `--retry-misses`
re-attempts the nulls (e.g. after a bot-wall spell).

**The cache is append-only, so `wc -l` is not progress.** Re-resolving a song appends a
fresh record rather than rewriting the old line — the last line for an id wins. Counting
lines therefore overstates coverage (once by ~3,900 lines during the first full crawl);
count **distinct ids** instead.

**Two drivers, one cache.** The nightly
([`scripts/streaming-links-nightly.sh`](../../scripts/streaming-links-nightly.sh),
launchd `com.pocketdj.streaming-links-nightly` at **06:00**, one hour after the digital
sync and two after the Apple Music sync so they never contend for the clone lock)
resolves a bounded batch (`POCKETDJ_LINK_BATCH`, default 800/night ≈ 1h), folds, then
commits **GitHub-before-S3** and publishes each changed index to its home bucket. Because
the resolver skips already-cached songs, the nightly naturally picks up whatever the
04:00 Apple Music sync just added. For bulk work there is
[`scripts/backfill-streaming-links.mjs`](../../scripts/backfill-streaming-links.mjs) — a
supervisor that runs the resolver in chunks with an adaptive delay, backing off and
cooling down when a chunk's miss rate crosses `--miss-backoff` (a bot-wall signal) and
aborting after `--max-stalls` consecutive stalls.

**The two drivers interlock.** Both drive Chromium against the same services and the
same cache, so running them concurrently makes each look like the other's bot-wall. The
supervisor honours the nightly's `<cacheDir>/.sync.lock`, taken **per chunk** rather than
per run: a multi-day manual crawl holding it up front would starve the nightly every
night (the failure mode the am-sync clone was built to avoid), so instead the nightly
waits at most one chunk (~9 min) and the manual run reports `waiting-for-lock`.
`--ignore-lock` opts out. Stale locks are reclaimed by pid probe, where **only `ESRCH`
counts as dead** — `EPERM` means the holder is alive under another uid, and treating it
as stale steals a live lock.

**A miss is usually permanent, and that shapes the retry economics.** Measured over the
first full crawl: songs resolved on the first attempt yield links at ~70–85%, but
re-attempting prior misses yields **~0.2%** (7 links per 3,840 vinyl songs) — the misses
are overwhelmingly records that genuinely aren't on Spotify or YouTube, not transient
blocks. Retrying the full miss set is therefore rarely worth its multi-day cost; crawling
*newly added* songs is (1,764 links from 1,334 songs).

---

## 2. Internal model — what the index becomes on-device

**Source of truth:** [`src/types/model.ts`](../../src/types/model.ts).

The internal model is a discriminated union on `type` (`'album' | 'song'`) stored in
IndexedDB, decoupled from the on-disk shape so the importer can normalize/migrate.
Key additions over the on-disk shape:

- `BaseItem.sourceId` — every item belongs to a `DataSource` (`analog` | `digital`;
  `streaming` reserved). The sentinel `ALL_SOURCE_ID = '__all__'` is the virtual
  "browse across every source."
- `AlbumItem.coverArtKey` — IndexedDB blob cache key, set after the cover is cached.
- `AlbumItem.audioBpm/audioCamelot/audioKey` — the rollup above.
- `SongItem.genre` — the **top-level genre CATEGORY** of the owning album, derived at
  import via `categorize`, so songs are filterable by genre ("soul songs at 80–90 BPM").
- Numeric, between-filterable fields stored as plain numbers on one axis: `year`,
  `lengthMs` (ms). Display formatting (mm:ss) happens only at the edge.

```
 DataSource { id, type:'analog'|'digital', name, itemCount:{albums,songs} }
   owns ▼ (by sourceId)
 MusicItem = AlbumItem | SongItem            (isAlbum / isSong type guards)
   AlbumItem  { artist,name, coverArtKey?,coverArtUrl?,coverArtSources?, genre?,year?,
                country?, trackIds[], pointer?,fileType?, enrichment?,
                audioTracks?[], audioDurationSec?, audioBpm?,audioCamelot?,audioKey? }
   SongItem   { albumId?, trackNumber?,year?, artist,name, genre?, lyrics?,lyricsStatus?,
                sentimentKeywords[], sentimentSource?, explicit, bpm,key,camelot?,
                lengthMs?, pointer?,fileType? }
```

**Reading the diagram.** A `DataSource` owns items by `sourceId`. A `MusicItem` is
either an `AlbumItem` (carrying its progressive art, the audio rollup, and ordered
`trackIds`) or a `SongItem` (carrying its derived genre category, sentiment, and the
nullable audio fields). Items are kept **distinct per source**, so multi-source
selection (vinyl + Apple Music) never collides.

---

## 3. Collections — pockets / playlists / setlists

**Source of truth:** [`src/types/collections.ts`](../../src/types/collections.ts).
These are **cross-source user collections** — no `sourceId`; items resolved by id at
view/realize time. (The full performance semantics are
[Chapter 4](./04-performance-engine.md); the *shape* lives here.)

```
 Pocket   pkt_   { name, kind:'harmonic'|'performance', songIds[], albumIds[],
                   childPocketIds[], notes?:PocketNote[] }   DAG, cycle-guarded; albums expand at realize
   PocketNote   pnt_  { id, text, position }   v2: free-text item ("poetry pocket"), orderable
                                                AMONG members by position in [pockets,albums,songs,notes]
 PlaylistFolder fld_ { id, name, createdAt, updatedAt }   v3: FLAT named group; carries NO member
                                                list (membership is Playlist.folderId — see below)
 Playlist pls_   { name, sequences:SequenceNode[], targetMs?, importedFrom?, folderId? }   folderId v3
   SequenceNode  { name, targetMs?, children: PlaylistNode[] }   sequences[0]=Default
     PlaylistNode = SongNode | AlbumNode | PocketNode | SequenceNode | TextNode(cue)
                    (each node may carry a performer `note`, and a source `sourceId`)
 Setlist  set_   { playlistId, name?, seed, generatedAt, totalMs, tracks:SetlistTrack[] }
   SetlistTrack  { songId, artist,name,bpm,camelot,lengthMs   (SNAPSHOT),
                   source:'explicit'|'pocket'|'autofill', sequenceName?, note?,
                   isText?, pocketId?, mixSuggestions?[] (DEFERRED) }
   set_now_playing · pls_now_playing   RESERVED reusable "Now Playing" setlist (§3.1)
```

**Reading the diagram.** A **Pocket** (`pkt_`) is a reusable grouping that nests
other pockets into a cycle-guarded **DAG** (only `kind:'harmonic'` is built;
`'performance'` reserved). A **Playlist** (`pls_`) is a **template**: ordered
`SequenceNode` chapters, each with an optional `targetMs` budget and recursive
`PlaylistNode` children (song/album/pocket/sub-sequence/free-text **cue**);
`importedFrom` marks an iTunes mirror. A **Setlist** (`set_`) is the **frozen
instance**: each `SetlistTrack` snapshots artist/bpm/camelot/length **inline** so it
reads standalone even if the catalog later changes; `source` records provenance; and
`mixSuggestions` is the **deferred AI seam** (Ch. 4). A **`PlaylistFolder`** (`fld_`) is
a **flat, named group** of playlists; it carries **no member list** — membership is the
optional **`Playlist.folderId`** back-reference (`nil` ⇒ top level), so a folder is just
an id + name + timestamps. The reserved `set_now_playing` / `pls_now_playing` ids back the
reusable Play/Shuffle setlist (§3.1).

### 3.1 The `CollectionsDocument` envelope, schema versioning, and folders (native)

**Source of truth:**
[`apple/PocketDJ/Models/CollectionsSchema.swift`](../../apple/PocketDJ/Models/CollectionsSchema.swift)
(`CollectionsDocument`, `PlaylistFolder`, `CollectionsMigration`).

The native app persists the whole collections graph as **one versioned, lenient-decode
`CollectionsDocument`** so the *shape* can evolve without breaking older docs:

```
 CollectionsDocument { schemaVersion, pockets[], playlists[], setlists[],
                       folders:[PlaylistFolder]  (v3),  lastAddTarget?,
                       recentAddTargets?:[AddTarget]  (UNVERSIONED additive — see below) }
   collectionsSchemaVersion = 7      additive-only · lenient (missing version ⇒ v0; missing lists ⇒ [])

 CollectionsMigration.migrate(doc):                      runs when doc.schemaVersion < current
   v1 → v2   pockets gain ordered notes:[PocketNote]    (each older pocket gets notes:[])
   v2 → v3   playlists gain folderId?  +  doc gains folders:[PlaylistFolder]
             (lenient decode already defaults folders→[] and every folderId→nil ⇒ top level;
              the migration just stamps schemaVersion — a no-op remap, the seam for a future
              folder-shape transform)
   v3 → v4   pockets gain folderId?     (lenient decode already defaults it → nil ⇒ top level; no-op remap)
   v4 → v5   NO stored-shape change — studio support is decoder + consumer behaviour, not new fields:
             (a) per-element LOSSY decode at every [PlaylistNode] + the [Playlist] list itself, and
             (b) studio namespaced ids (smp_/lp_/ptn_) riding the EXISTING songIds / SongNode arrays
             (both are behaviour, so the mapping forward is again the no-op identity; the bump just
              makes the version visible + reserves the seam for a future studio-shape transform)
   v5 → v6   pockets AND playlists gain SOURCE PROVENANCE (all optional ⇒ nil on hand-made items):
             sourcePlaylistId? + sourceName?   which catalog playlist Convert / Duplicate created it from
             sourceSongIds?                    the source membership at the last sync (3-way-merge base)
             sourceSyncEnabled?                per-item opt-out (nil ⇒ enabled) · sourceSyncedAt?
   v6 → v7   pockets AND playlists gain lastPlayedAt? (epoch ms) — stamped by
             CollectionsStore.markPlayed on ▶ Play, OUTSIDE mutatePocket/mutatePlaylist so
             updatedAt (the "Last updated" signal) is never disturbed; powers the
             "Recently played" collection sort (nil ⇒ never played ⇒ sorts last); no-op remap
```

**Reading it.** `schemaVersion` is bumped on any shape change and
`CollectionsMigration.migrate` upgrades older documents on load; decode is **lenient**
(a missing version ⇒ v0, a missing list ⇒ empty) and **additive-only** (never remove or
repurpose a field). The **v2→v3** step is the playlist-folders one: playlists gained an
optional **`folderId: String?`** and the document gained a **flat `folders:
[PlaylistFolder]`** list. It's fully back-compat in *both* directions — a v2 doc migrates
forward (folders defaults to `[]`, every `folderId` stays `nil` ⇒ top level), and a v3 doc
**loads degraded on a v2 app** (the unknown `folders` / `folderId` keys are ignored,
playlists intact). Deleting a folder keeps its playlists (they fall back to top level —
`folderId ⇒ nil`); folders are name-ordered (case-insensitive) for stable display. **v3→v4**
extended the same folder idea to **pockets** (`Pocket.folderId?`, `nil ⇒ top level`) — the
identical additive, lenient, no-op-remap shape.

**The v4→v5 step — studio items ride the collections graph.** This is the step the
**Performance tab (Studio)** landed, and it is deliberately a **behaviour** change with
**no new stored fields** — so it follows the additive/lenient template exactly. Two things
turned on: (a) **per-element lossy decoding**, shipped **everywhere** a `[PlaylistNode]` is
decoded (a chapter's `children`, the nested `children` recursion) *and* on the `[Playlist]`
list itself — each element decodes into a failable box whose failure drops **that element
only**, so one unknown-kind node can never take down a chapter, a list, or the document; and
(b) **studio namespaced ids** (`smp_` samples, `lp_` loops, `ptn_` sequences) that ride the
**existing** `Pocket.songIds` / `SongNode.songId` string arrays — **no new `PlaylistNode.Kind`
case**, because a new synthesized-`Codable` case would wipe playlists on any older build that
hit it (the trap the lossy decoder now insures against for all *future* kinds). The migration
is again a **pure no-op remap** (nothing to transform — the ids were always valid strings),
so a v4 doc migrates forward untouched and a **v5 doc loads degraded on a v4 app**: an older
build without the lossy decoder that trips on a studio-bearing node now drops just that node
(once every reader is v5) rather than the whole list, and even a pre-v5 reader keeps every
node it *does* understand. Studio ids **carry through import / merge / backup unchanged** —
they are plain strings in the same arrays folders and members already travel in, so the
`importCollection` remint and the backup zip (`BackupZip.swift`) need **no** studio-specific
handling; the import-remint leaves unknown-prefix ids untouched, and the referenced media
stays device-local (documented in [Ch. 4 §8.6](./04-performance-engine.md#86-collections-integration--namespaced-ids-schema-v5-lossy-decode-and-the-consumer-fence)).
The full per-consumer resolution policy (which consumers *resolve* a studio id vs. *fence* it
out of rip/burn/CSV/autofill) lives there.

**The v5→v6 step — converted collections follow their source playlist.**
`convertToPocket(source:)` and `createPlaylist(_:songIds:source:)` (the Duplicate-as-editable-
playlist path) now stamp **provenance** on the item they create (`sourcePlaylistId` +
`sourceName` identify the catalog playlist, `sourceSongIds` snapshots the membership) and
every **catalog assign** (cache seed + network refresh, `AppModel.onCatalogAssigned` → wired
in `PocketDJApp.init`) runs `CollectionsStore.syncConvertedCollections(with:)` — a **three-way
merge** per sync-enabled item against its source playlist using the snapshot as the base:
source *adds* (in source, not in snapshot) append — to the pocket's `songIds` / the playlist's
DEFAULT chapter (`sequences[0]`); source *removals* (in snapshot, not in source) drop — from
the pocket (their `songRepeats` too) / every matching `.song` node recursively (chapters, text
cues, albums, nested pockets untouched); everything else — the user's own adds, removes,
reorders, extra chapters — lives outside both sets and **survives**. The snapshot then
advances, and a no-change refresh persists nothing (no `save()`/`updatedAt` churn). Gates: the
**global** `SettingsStore.syncConvertedPockets` toggle (default ON, checked at the wiring
site; surfaced in **Settings ▸ Apple Music ▸ Syncing**, `AppleMusicSettingsView`, alongside the Apple Music library
re-index and a manual "Sync from sources now" pass), the **per-item** `sourceSyncEnabled` (the
⋯ menus' "Sync with source"), and the manual "Sync from source now" menu actions
(`syncPocketFromSourceNow` / `syncPlaylistFromSourceNow`) which ignore both. An item whose
source playlist is **missing** from a refresh (source disabled, playlist deleted upstream) is
left untouched — a vanished source never silently wipes the user's copy.

**`recentAddTargets` — the Recent quick-add MRU (unversioned additive).** The document also
carries an optional **`recentAddTargets: [AddTarget]?`** — the last few "Add to…" targets,
most-recent first, **deduped by `(kind, id)` ignoring `sequenceId`** (a re-add to another
chapter refreshes the row, freshest chapter wins) and capped at
`CollectionsStore.maxRecentTargets = 10`; `AddToCollectionView` surfaces the top **3**
resolvable entries as one-tap quick-add rows. It is deliberately **not** a schema bump:
additive-optional with lenient decode (`try?` ⇒ nil ⇒ `[]` in the store), so a pre-F11
document loads with every collection intact, and it rides the **same** collections CloudSync
as `lastAddTarget` (the top-of-list entry is exactly that value), so the MRU syncs across
devices. Both are updated together at the `addSong(_:to:)` / `addAlbum(_:to:)` choke points
(one write); the read-only *source*-playlist add path deliberately touches **neither**, so a
"Last used" repeat can never silently drop the Apple Music write-back half of that add.

**Folders survive import / merge / backup.** Because a folder is pure id+name, it carries
cleanly through every transfer path (`CollectionsStore.importCollection` + the backup zip):
on a full-doc import, fresh folder ids are minted up-front (`folderIdMap`) and each imported
playlist's `folderId` is **remapped** through that map (a ref to a folder *not* in the
import is dropped ⇒ top level), exactly like the pocket-id remap. The native backup zip
([`apple/PocketDJ/Services/BackupZip.swift`](../../apple/PocketDJ/Services/BackupZip.swift))
adds a **`folders.json`** member alongside `pockets`/`playlists`/`setlists`, decoded
leniently (absent ⇒ `[]`) so an older backup restores without folders. The full
playback/realize/Play-Shuffle semantics that consume these live in
[Ch. 4 §6](./04-performance-engine.md#6-play--shuffle--the-reusable-now-playing-setlist-native).

---

## 4. Where the catalog is stored & loaded

- **Web:** IndexedDB via `src/storage` (`importIndexJson`, `repo`, `db`); first boot
  `seedIfEmpty()` pulls `current-index.json`; Apple Music is opt-in. (Ch. 7)
- **Native:** decoded into `IndexJSON` via `CatalogService`, backed by an **explicit
  per-source disk cache** so the catalog opens fully OFFLINE (§4.1). Edits are a separate
  overlay (Ch. 7).

### 4.1 The native offline catalog cache — `CatalogService` + `AppModel` degradation

**Source of truth:**
[`apple/PocketDJ/Services/CatalogService.swift`](../../apple/PocketDJ/Services/CatalogService.swift)
(per-URL disk cache) and
[`apple/PocketDJ/State/AppModel.swift`](../../apple/PocketDJ/State/AppModel.swift)
(`fetchIndex` multi-source merge).

**Why a file cache and not just `URLCache`.** `CatalogService.loadIndex()` fetches each
source URL with `cachePolicy = .returnCacheDataElseLoad`, but the shared `URLCache`
silently refuses to persist responses past its small default capacity — and a real catalog
(1,300+ albums) routinely exceeds it, so an offline relaunch had nothing to fall back to.
So on every **successful** load — *after* a valid `IndexJSON` decode, never on a partial
response — the raw bytes are persisted to an explicit file cache, and any later **failure**
(no network / server down / non-2xx) serves the last good index from disk instead of
throwing.

```
 CatalogService.loadIndex()  (per source URL)
   try fetch (returnCacheDataElseLoad, 30s) → decode IndexJSON
        ├─ ok    → writeCache(rawBytes, for:url)  → return fresh index
        └─ throw → loadCachedIndex(for:url) ?? rethrow      (OFFLINE fallback)

 disk cache: Application Support/catalog-cache/<sha256(url.absoluteString)>.json
   cacheDirectory(_:)  Application Support/catalog-cache/  (dir override = unit-test seam)
   cacheFileURL(for:)  SHA-256 of the URL string (CryptoKit, NOT Swift's per-process
                       Hasher — that wouldn't survive relaunch) → "<hex>.json"
   writeCache(_:for:)  atomic, best-effort (a cache-write failure never fails the load)
   loadCachedIndex(for:)  read + decode, or nil when there's no (valid) cache
```

**Reading it.** The cache is keyed **per source URL** by a stable **SHA-256** of
`url.absoluteString` (deliberately not Swift's `Hasher`, which is per-process-seeded and so
wouldn't survive a relaunch), giving an O(1), flat `<hex>.json` filename under
`Application Support/catalog-cache/`. Writes are `.atomic` and best-effort; the cache is
only ever written after a clean decode, so a truncated download never poisons it. The
`dir` override on every static helper is the unit-test seam (a temp dir) so the
write→read round-trip is testable without touching Application Support.

**Multi-source graceful degradation (`AppModel.fetchIndex`).** A user can enable several
sources at once (vinyl + Apple Music); `fetchIndex` loads `settings.enabledSourceURLs`,
each through its own `CatalogService` (hence its own disk cache). A per-source load that
throws is **swallowed** (its first error retained as `firstError`) so the *other* sources'
cached catalogs still open — an un-cached source (never loaded online) plus no network must
not hide an already-cached one. The whole load fails **only when every source failed**
(`indexes.isEmpty` ⇒ rethrow `firstError ?? URLError(.cannotLoadFromNetwork)`); otherwise it
returns the merge of whatever loaded.

### 4.2 The rips manifest cut fields + the offline-burn `BurnItem` cut fields

The catalog index isn't the only data shape clients persist: the **rips manifest** and the
native **offline-burn store** carry their own per-song records. The manifest's full
`ManifestEntry` shape and the burn store live in
[Ch. 5 §5 / §9](./05-playback-and-rip-on-demand.md#5-the-rips-manifest--job-payloads); the
**analog per-song cut** export adds matching fields to both, recorded here because they are
part of the data model the burn consumes.

**Source of truth:** `scripts/rip-server.mjs` (producer of the manifest cut fields),
[`apple/PocketDJ/State/RipsStore.swift`](../../apple/PocketDJ/State/RipsStore.swift)
(`ManifestEntry`, consumer) and
[`apple/PocketDJ/State/BurnStore.swift`](../../apple/PocketDJ/State/BurnStore.swift)
(`BurnItem`).

```
 ManifestEntry  (+ analog-cut fields; ANALOG only, nil ⇒ album-only, no cut)
   cutKey?     "rips/<songId>.cut.mp3"   the per-song chunk sliced out of the album,
               under the PUBLIC rips/ prefix, distinguished from a cloud rip's
               rips/<songId>.mp3 by the `.cut.` infix; tagged title/artist/album (ID3v2.3)
   cutBytes?   the cut object's size            cutRippedAt?  epoch-ms the cut was uploaded
   (album `key` + `startMs` stay the PLAYBACK source; the cut is burn-only)

 BurnItem  (+ analog-cut fields; both optional for back-compat decode)
   cutFileName?     the per-song cut's filename in the burn folder (digital-style name,
                    pairs with the per-song sidecar) — the single-track view for DJ
                    software, alongside the whole-album backcase. nil ⇒ no cut exported.
   cutDownloadedAt? the S3 Last-Modified epoch-ms at download → a later burn re-pulls
                    when the S3 cut is NEWER (the manual-recut auto-repull)
```

**Reading it.** When the rip server slices an analog album, it also `ffmpeg -ss/-t`-cuts
each song out (duration = catalog `length`, else manifest `durationMs`, else derived
`pointer.endMs - startMs`), tags it (title/artist/album ID3v2.3), uploads it to
`rips/<songId>.cut.mp3`, and stamps the entry with **`cutKey` / `cutBytes` / `cutRippedAt`**
(`POST /backfill-cuts` retro-slices entries missing a cut; `POST /retag-cuts` is a tag-only
remux). Playback is **unchanged** — the album `key` + `startMs` seek remain the source; the
cut exists solely for the burn. On the burn side, `BurnStore.exportAnalogCuts` downloads each
`cutKey` into the user's burn folder under a descriptive per-song name and records
**`cutFileName`** + **`cutDownloadedAt`** on the `BurnItem`. `cutDownloadedAt` holds the S3
`Last-Modified` epoch-ms (via `RipsStore.remoteLastModifiedMs`), so a later burn re-pulls only
when the S3 cut is newer (a manual re-upload bumps `Last-Modified`) — deleting the stale cut
before writing the update, and keeping the existing cut offline / on a download failure. Both
fields are optional so older burn records decode unchanged; `finalizeBurn` preserves them when
the background album-download rebuilds the item.

### 4.3 The rips manifest beat-grid + stem fields

The manifest carries two more **additive** analysis groups, produced by the rip server's
beat-grid and Stemify passes (the producers + flow are
[Ch. 5 §15](./05-playback-and-rip-on-demand.md#15-stems-end-to-end--server-stemify-offline-stem-store-and-stem-audition));
recorded here because they're part of the data shape the native `ManifestEntry`
([`RipsStore.swift`](../../apple/PocketDJ/State/RipsStore.swift)) decodes and the Mix engine
consumes.

```
 ManifestEntry  (+ BEAT GRID — all optional ⇒ back-compat)
   beatGridBpm?       the tempo MEASURED on the exact ripped/cut file (Mix Sync prefers this
                      over the catalog bpm — Ch.4 §7.4)
   firstBeatMs?  firstDownbeatMs?   grid phase anchors (downbeat = the Sync phase reference)
   beatsPerBar?  tempoConfidence?  tempoVar?  steady?      grid shape + a "steady tempo" flag
   beatgrid?          S3 key of a LAZY per-beat sidecar  rips/analysis/<id>.json
   analysisVersion?   the SHARED bpm/key/beat-grid version stamp (distinct from stemVersion)

 ManifestEntry  (+ STEMS — Demucs; all optional ⇒ presence of stemVersion ⇒ "stemmed")
   stems?:{ vocals, drums, bass, other }   the 4 PUBLIC S3 keys  rips/stems/<songId>/<stem>.mp3
   stemModel?  "htdemucs" (Demucs v4 default)       stemVersion?  int (canonical "is stemmed")
   stemFormat?  "mp3"|"flac"     stemmedAt?  epoch-ms     stemBytes?  total size of the 4 stems
```

**Reading it.** The **beat grid** is a *measured* tempo + downbeat phase computed on the
**exact file** that plays (a digital song's mp3, an analog song's per-song cut) — `beatGridBpm`
is what the Mix engine's beat-matching **prefers over the catalog `bpm`**, and `firstDownbeatMs`
is its phase reference (Ch. 4 §7.4); `steady` flags a reliable, non-drifting grid.
`analysisVersion` is the shared bpm/key/beat-grid stamp, **separate from `stemVersion`**, so
re-stemming and re-gridding are independent. The **stems** group records the four public stem
keys plus Demucs provenance; the singular **`stemVersion`** is the canonical "this song is
stemmed" signal the client (`RipsStore.isStemmed`) and the Burn (Ch. 5 §9) both test. Both
groups decode as optionals, so a song with neither — the common case — loads exactly as before.
(Stems are **per-song** even for analog: a vinyl song stems its *cut*, never the shared album
side, so a stem key is always `rips/stems/<songId>/…`.)

## 5. Favorites — the per-profile ♥ document

**Why its own document, and not a field.** A ♥ is per-*profile* user state, not catalog
state, so it can't ride the index (read-only, machine-produced, shared by every install).
It could have ridden `CollectionsDocument` (§3.1) — but that document is the thing every
transfer path carries: the backup zip, the playlist/pocket zips, `importCollection`'s
id-remint. Favorites must **not** travel that way. The owner exporting a pocket to a friend
must not ship their taste with it, and an import must never overwrite the importer's hearts.
So favorites are a **separate Application Support document with its own sync registration**
— the `DiscoverAddsStore` durable-JSON pattern (decode-on-init, atomic save, `PDJ_USE_FIXTURE`
launch seam) — and they appear in **neither** `BackupZip` nor the interchange family
([Ch. 7 §3.5](./07-distribution-and-clients.md#35-the-interchange-format-family--three-zips-one-envelope)).
iCloud, not a file handed to someone, is the only way a ♥ moves between devices.

**Source of truth:**
[`apple/PocketDJ/State/FavoritesStore.swift`](../../apple/PocketDJ/State/FavoritesStore.swift)
(the document + the store),
[`apple/PocketDJ/State/FavoritesSyncService.swift`](../../apple/PocketDJ/State/FavoritesSyncService.swift)
(`Seed`), and the registration in
[`apple/PocketDJ/PocketDJApp.swift`](../../apple/PocketDJ/PocketDJApp.swift).
The two-way Apple Music half — the Web API, the owner gate, the tester seed — is
[Ch. 7 §5.5](./07-distribution-and-clients.md#55-apple-music-favorites--the-web-api-two-way-sync-owner-gated).

```
 Application Support/pocketdj-favorites.json      (FavoritesStore.defaultURL)
   Document { schemaVersion = 1, entries:[Entry], seedVersion? }
     Entry { songId, favorited:Bool, atMs, appleMusicId?, pushedAtMs? }
       favorited:false  =  TOMBSTONE, not a deleted row  (absence ⇒ "never touched")
       atMs             =  when the USER last toggled  (Apple Music reconcile tie-break)
       appleMusicId?    =  catalog id captured AT TOGGLE TIME, so a queued push needs no
                           re-resolve.  nil ⇒ vinyl / "My Digital" / Studio ⇒ LOCAL-ONLY
       pushedAtMs?      =  last successful mirror to Apple Music.
                           (pushedAtMs ?? -1) < atMs  ⇒  still owed an outbound push
     seedVersion?       =  highest tester-seed generation already applied (nil ⇒ never)

   in memory:  byId:[songId:Entry]  (truth)  +  favoriteIds:Set<String>  (derived cache,
               so a row's isFavorite and the ~90k-row Browse filter are both O(1))

 CloudSync registration  (PocketDJApp.init)
   cloudSync.register("favorites", fileURL: favorites.syncFileURL) { favorites.reloadFromDisk() }
     ⇒ the signed-in Apple ID's PRIVATE CloudKit DB — same-URL doctrine as the other
       session documents; a pull re-decodes and fires NO onChanged (see below)

 favorites-seed.json      (Config.favoritesSeedURL = catalogBase + "favorites-seed.json")
   Seed { version:Int, songIds:[String], appleMusicIds?:{songId:appleMusicId} }
     produced by FavoritesSyncService.exportSeed (owner-only, filters on appleMusicId != nil)
```

**Reading the diagram.** The document is a flat `entries` array keyed by `songId`, adopted on
load into `byId` (the truth) plus a derived `favoriteIds` **Set** — the Browse favorite filter
runs per row over ~90k songs, so it must never walk a dictionary
([Ch. 6](./06-search-and-discovery.md)). Three fields carry the load-bearing semantics.
**`favorited:false` is a tombstone**, not a deletion: absence means "never touched", and the
two consumers that need the distinction are the tester seed (which fills only untouched songs,
so it cannot resurrect a deliberate un-♥) and the Apple Music pull (which must tell "never
favorited" from "deliberately unfavorited"). **`atMs`** timestamps the *user's* toggle and is
the reconcile tie-break — `applyRemote` refuses to overwrite an entry whose `atMs` is newer
than the observation, so a ♥ made offline survives a pull that still shows the old upstream
state. **`appleMusicId`** is captured at toggle time and is the structural reason vinyl /
"My Digital" / Studio favorites can never be dragged into an Apple Music round-trip: they
have no catalog id, `pendingPushes` filters on `appleMusicId != nil`, and the exported seed
does too.

**Why the CloudSync callback must not re-emit.** `FavoritesStore.onChanged` fires for
**user-originated** writes only (`set`/`toggle`), and the app wires it to
`FavoritesSyncService.pushNow`. `reloadFromDisk` (the CloudSync pull) and `applySeed`
deliberately do **not** fire it: a pull is already-known state, and re-emitting it would push
the cloud's view straight back up to Apple Music on every launch, on every device, forever.
`applyRemote` (the inbound Apple Music half) likewise returns without `onChanged`.

**Bulk writes coalesce.** `save()` re-encodes and atomically rewrites the whole document, and
this is a `@MainActor` type — so the inbound Apple Music reconcile, which can touch every
catalog song, would be O(n²) encoding plus *n* atomic writes synchronously on the main actor
(a multi-second launch freeze). `withCoalescedSaves { … }` is the bulk seam: re-entrant, it
collapses every nested `save()` into one trailing write, and still writes exactly once if the
body throws partway.

**Provisional ids are remapped like collections.** A ♥ placed on a Discover/recognizer add
carries a provisional `amrec_` id. When the nightly indexer lands the real track,
`AppModel.onDiscoverSupersede` fans out to **both** `CollectionsStore.remapSongIds` and
`FavoritesStore.remapSongIds` — miss the second and the heart silently detaches from the song
it was placed on. A destination the user has already touched explicitly wins over the
remapped entry.

**The seed document** is a separate, tiny public artifact on the same CloudFront catalog base
as the index ([Ch. 7 §1](./07-distribution-and-clients.md#1-aws-s3--cloudfront--the-public-content-host)).
It carries PocketDJ **song ids** (not Apple Music ids) plus an optional `songId →
appleMusicId` map, so a seeded ♥ is still pushable if that install later becomes an owner.
`version` is monotonic (the exporter stamps a UNIX timestamp) and `applySeed` only applies a
version **greater** than the stored `seedVersion`, which is what makes the seed a one-time
event rather than a per-launch overwrite.

## 6. Collection activity — the append-only add/♥/remove log

**Why its own store, and not `PlayHistoryStore`.** The play log's `PlayEvent` is
deliberately song-play-centric — a 30s same-song re-count window plus the count/last-played
indexes that feed the "recently played" sort (Ch. 6). An **add / heart / unheart / remove**
is a different *kind* of fact (no re-count window, no per-song aggregate), so bolting it onto
`PlayEvent` would corrupt those reads. It gets its own append-only document with zero
wipe-risk to the play log.

**Source of truth:**
[`apple/PocketDJ/State/CollectionActivityStore.swift`](../../apple/PocketDJ/State/CollectionActivityStore.swift)
and the wiring in [`PocketDJApp.swift`](../../apple/PocketDJ/PocketDJApp.swift).

```
 Application Support/pocketdj-collection-activity.json
   Document { schemaVersion = 1, installId, events:[ActivityEvent] }   lenient decode
     ActivityEvent { id:UUID, at(ms), kind:'add'|'heart'|'unheart'|'remove',
                     itemId, itemTitle?  (SNAPSHOT at record time),
                     collectionId? collectionKind? collectionName?  (nil for ♥ — not scoped) }
   maxEvents = 20_000  (append-only, oldest dropped past the cap)

 fed by two hooks (PocketDJApp.init):
   CollectionsStore.onActivity   add/remove  (emitted at the add/remove choke points)
   FavoritesStore.onChanged      heart/unheart  (the same user-originated-only callback §5)
 consumed by HistoryView — a Plays | Activity segmented control; Activity is the
   newest-first timeline ("Added X to Y" · "♥ Hearted Z" · "Removed X from Y")
```

**Reading it.** Same durable-JSON idiom as its siblings (atomic save, decode-on-init,
`PDJ_USE_FIXTURE` launch seam, a monotonic `revision` the view keys recomputes on).
`itemTitle` / `collectionName` are **snapshots** at record time, so a row stays readable
after the item leaves the catalog or the collection is renamed/deleted (Studio
`smp_`/`lp_`/`ptn_`/`tk_` items have no catalog song — their title is snapshotted too, or
the row falls back to the id). The stable per-event `UUID` plus a document `installId` make
cross-device merge a clean **`union(by: id)`** — and that is exactly what the CloudSync pull
does: the `"collection-activity"` registration's `reloadFromDisk` **deliberately diverges**
from the whole-document LWW replace the other stores use, instead **unioning** the disk
doc's events into memory by event id (idempotent, re-sorted chronologically) and saving —
a wholesale replace would let device B's log silently overwrite device A's local events.
`clear()` deletes the on-disk file entirely (the AccountDeletionService "no residual file"
contract), keeping the install identity.

## Next

→ [Chapter 4 — Performance Engine](./04-performance-engine.md)
