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
`pointer` links back to the raw file (`originalFilename`) and per-segment offsets.

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
   {id, storeId|null}  (resumable, paced,       never drops resolved ids; misses
    adaptive 403/429 backoff)                    ignored)
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
                       folders:[PlaylistFolder]  (v3),  lastAddTarget? }
   collectionsSchemaVersion = 3      additive-only · lenient (missing version ⇒ v0; missing lists ⇒ [])

 CollectionsMigration.migrate(doc):                      runs when doc.schemaVersion < current
   v1 → v2   pockets gain ordered notes:[PocketNote]    (each older pocket gets notes:[])
   v2 → v3   playlists gain folderId?  +  doc gains folders:[PlaylistFolder]
             (lenient decode already defaults folders→[] and every folderId→nil ⇒ top level;
              the migration just stamps schemaVersion — a no-op remap, the seam for a future
              folder-shape transform)
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
`folderId ⇒ nil`); folders are name-ordered (case-insensitive) for stable display.

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
- **Native:** decoded into `IndexJSON` via `CatalogService`; cached by URLCache.
  Edits are a separate overlay (Ch. 7).

## Next

→ [Chapter 4 — Performance Engine](./04-performance-engine.md)
