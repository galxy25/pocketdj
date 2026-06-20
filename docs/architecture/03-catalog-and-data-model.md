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
  │              sourceName?, counts, deferredFields[], batches? }
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
  │   ├─ bpm? · key? · camelot?   (AUDIO stage; null until analyzed)
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
`undefined`, so "pending" stays explicit); `pointer` links back to the raw file
(`originalFilename`) and per-segment offsets.

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
                   childPocketIds[] }      DAG, cycle-guarded; albums expand at realize
 Playlist pls_   { name, sequences:SequenceNode[], targetMs?, importedFrom? }
   SequenceNode  { name, targetMs?, children: PlaylistNode[] }   sequences[0]=Default
     PlaylistNode = SongNode | AlbumNode | PocketNode | SequenceNode | TextNode(cue)
                    (each node may carry a performer `note`, and a source `sourceId`)
 Setlist  set_   { playlistId, name?, seed, generatedAt, totalMs, tracks:SetlistTrack[] }
   SetlistTrack  { songId, artist,name,bpm,camelot,lengthMs   (SNAPSHOT),
                   source:'explicit'|'pocket'|'autofill', sequenceName?, note?,
                   isText?, pocketId?, mixSuggestions?[] (DEFERRED) }
```

**Reading the diagram.** A **Pocket** (`pkt_`) is a reusable grouping that nests
other pockets into a cycle-guarded **DAG** (only `kind:'harmonic'` is built;
`'performance'` reserved). A **Playlist** (`pls_`) is a **template**: ordered
`SequenceNode` chapters, each with an optional `targetMs` budget and recursive
`PlaylistNode` children (song/album/pocket/sub-sequence/free-text **cue**);
`importedFrom` marks an iTunes mirror. A **Setlist** (`set_`) is the **frozen
instance**: each `SetlistTrack` snapshots artist/bpm/camelot/length **inline** so it
reads standalone even if the catalog later changes; `source` records provenance; and
`mixSuggestions` is the **deferred AI seam** (Ch. 4).

---

## 4. Where the catalog is stored & loaded

- **Web:** IndexedDB via `src/storage` (`importIndexJson`, `repo`, `db`); first boot
  `seedIfEmpty()` pulls `current-index.json`; Apple Music is opt-in. (Ch. 7)
- **Native:** decoded into `IndexJSON` via `CatalogService`; cached by URLCache.
  Edits are a separate overlay (Ch. 7).

## Next

→ [Chapter 4 — Performance Engine](./04-performance-engine.md)
