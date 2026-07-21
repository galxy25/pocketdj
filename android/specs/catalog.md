# Catalog contract — Android Phase 1

Implementation contract for the Android catalog layer (fetch → cache → decode →
merge → Browse). Every claim below is verified against the iOS/PWA source in this
worktree and cited as `file:line`. The iOS behaviour is the contract; Android
mirrors it with OkHttp + kotlinx.serialization + a file cache (locked decision 5,
`docs/ARCHITECTURE-ANDROID.md:39-44`).

---

## 1. Endpoints (exact URLs)

Base host per environment (`apple/PocketDJ/Support/Config.swift:14-19`):

| Environment | `catalogBase` |
|---|---|
| dev | `https://djictbz9w796r.cloudfront.net` |
| **prod (ship this)** | `https://d2p4cubg6se03u.cloudfront.net` |

Catalog documents, all `catalogBase + path` (`Config.swift:36-46`):

| Source name (exact string) | Path | Cite |
|---|---|---|
| `My Vinyl` (default source) | `/current-index.json` | `Config.swift:36`, default name `apple/PocketDJ/Settings/SettingsStore.swift:560` |
| `Apple Music (Local)` (opt-in) | `/apple-music-index.json` | `Config.swift:39-40` |
| `My Digital` (opt-in) | `/digital-index.json` | `Config.swift:45-46` |

Related documents on the same base (out of catalog scope but referenced here):

- **Lyrics text**: `{catalogBase}/lyrics/<songId>.txt` — fetched on demand ONLY
  when `song.lyricsStatus == "found"`, cached to a flat disk cache
  (`apple/PocketDJ/Services/LyricsStore.swift:64-82`; cache dir
  `Application Support/lyrics-cache/`, `LyricsStore.swift:32-43`). The index
  itself carries **no lyric text** (the `lyrics` key exists on some vinyl songs
  but is always `null` — verified over all 12,525 songs).
- **Online-search config**: `{catalogBase}/search-config.json` →
  `{ host, region, index }` (`Config.swift:75`; live file has
  `host: mii9dwge3uiee2tvivt5.aoss.us-west-2.on.aws`, `index: pocketdj`).
  Read at launch so the aoss host can change without a client rebuild.
- **Favorites seed**: `{catalogBase}/favorites-seed.json` (`Config.swift:70`) —
  not Phase 1.

### Art URL scheme

`IndexAlbum.coverArtSources[].url` and `coverArt` are either **root-relative**
(`/art/<albumId>.jpg` — a CDN thumbnail on the SAME CloudFront host) or already
**absolute** (an iTunes/Discogs cover). Resolution rule
(`Config.swift:89-94`): if the string starts with `/`, resolve against
`catalogBase`; otherwise use it as-is. Candidate ordering
(`apple/PocketDJ/Models/IndexModels.swift:105-112`): every `coverArtSources`
entry **in array order first** (the indexer puts `type:"cdn"` first), then
`coverArt` as the final fallback. Verified live example:
`coverArtSources: [{type:"cdn", url:"/art/alb_413cd2b29d9c.jpg", cors:true}, {type:"remote", url:"https://i.discogs.com/…", cors:false}]`.

Android: implement the same `artUrl(raw: String)` helper and feed the ordered
candidate list to Coil (first success wins).

---

## 2. Top-level document shape

`IndexJSON` (`apple/PocketDJ/Models/IndexModels.swift:6-21`; canonical TS shape
`src/types/index-json.ts`, book chapter
`docs/architecture/03-catalog-and-data-model.md:21-42`):

| Field | Type | Optional | Notes |
|---|---|---|---|
| `manifest` | Manifest | required | provenance + counts |
| `albums` | IndexAlbum[] | required | parallel array |
| `songs` | IndexSong[] | required | parallel array |
| `playlists` | IndexPlaylist[] | **optional** | Apple Music user-playlist mirrors; absent on vinyl/digital fixtures (`IndexModels.swift:10-12`) |

**Manifest** (`IndexModels.swift:51-61`) — the native client models only:

| Field | Type | Optional |
|---|---|---|
| `source` | String | yes |
| `generatedAt` | String (ISO-8601) | yes |
| `sourceName` | String | yes — **fallback display name is `"Collection"`** (`apple/PocketDJ/State/AppModel.swift:661`) |
| `counts` | `{ albums: Int?, songs: Int? }` | yes (all inner fields optional, `IndexModels.swift:58-61`) |

The live manifests carry many more keys (`schemaVersion`, `sourceType`,
`deferredFields`, `cloudReindex`, `playlistsCount`, rich `counts`) — **ignore
unknown keys**; the iOS decoder models only the above (`IndexModels.swift:4-5`).

**IndexPlaylist** (`IndexModels.swift:25-29`):
`{ id: String, name: String, songIds: [String] }` — read-only, rendered as
"From your sources" rows tagged with the source's name.

---

## 3. Album schema

`IndexAlbum` — the fields the client decodes (`IndexModels.swift:81-99`).
Everything else in the JSON (`pointer`, `enrichment`, `indexing`) is present in
the documents but **deliberately not modelled** — decode must ignore unknown keys.

| Field | Type | Optional | Notes |
|---|---|---|---|
| `id` | String | required | `alb_` + 12-hex content hash (`docs/architecture/03-catalog-and-data-model.md:26`) |
| `artist` | String | required | |
| `name` | String | required | |
| `coverArt` | String | yes, **may be `null`** (digital index has `"coverArt": null`) | absolute or root-relative art URL |
| `coverArtSources` | `[{type:"cdn"\|"remote", url: String, cors: Bool?}]` | yes | ordered, cdn-first (`IndexModels.swift:63-67`) |
| `genre` | String | yes, may be `null` | raw genre string (e.g. `"Hip-Hop/Rap"`) |
| `year` | Int | yes, may be `null` | |
| `country` | String | yes | vinyl only in practice |
| `trackList` | [String] | **required** | ordered `IndexSong.id` refs |
| `fileType` | String | yes | e.g. `"mp3"`, `"aac"` |
| `audioTracks` | [AudioTrack] | yes | vinyl only; audio segmentation, count may differ from `trackList` |
| `audioDurationSec` | Double | yes | |
| `appleMusicId` | String | yes | iTunes album `collectionId`, bare numeric string (`IndexModels.swift:94-99`) |

**AudioTrack** (`IndexModels.swift:70-79`) — all fields optional:
`{ trackNumber: Int?, startMs: Int?, endMs: Int?, durationMs: Int?, bpm: Double?, key: String?, camelot: String?, keyStrength: Double? }`.

Field presence by live document (verified by key-union over every row):

- `current-index.json` (vinyl): 1,361 albums; all have `trackList`/`fileType`/`audioTracks`/`audioDurationSec`; `coverArt` on 1,160, `genre` 1,161, `year` 1,154, `country` 900, `coverArtSources` 1,160.
- `apple-music-index.json`: 11,436 albums; **no** `coverArt`/`coverArtSources`/`audioTracks` at all; `genre` 11,383, `year` 11,406.
- `digital-index.json`: 59 albums; `coverArt`/`genre`/`year` present but often `null`.

---

## 4. Song schema

`IndexSong` — decoded fields (`IndexModels.swift:115-136`). The JSON also carries
`pointer`, `sentimentSource`, `explicitSource`, `explicitCategories`,
`cloudReindex`, `lyrics` (always null), `lyricsSource` — all **ignored** by the
native model; do the same.

| Field | Type | Optional | Notes |
|---|---|---|---|
| `id` | String | required | `sng_` + 12-hex hash; Apple Music songs are namespaced INSIDE the hash input (`sng_+sha1("digital\|Apple Music (Local)\|<persistentID>")[:12]`, `docs/architecture/03-catalog-and-data-model.md:166-167`) — ids are globally unique plain strings, no client parsing |
| `albumId` | String | optional | join to `IndexAlbum.id` |
| `artist` | String | required | |
| `name` | String | required | |
| `trackNumber` | Int | optional | |
| `year` | Int | optional, may be `null` | |
| `sentimentKeywords` | [String] | optional | vinyl only |
| `explicit` | Bool | optional | absent on digital index |
| `bpm` | Double | optional, **often present-but-`null`** | `null` = "not analyzed yet" (all 93,185 AM songs carry `"bpm": null`) |
| `key` | String | optional, may be `null` | e.g. `"G minor"` |
| `camelot` | String | optional, may be `null` | e.g. `"6A"` |
| `length` | Int | optional | **milliseconds** (`IndexModels.swift:127`) |
| `fileType` | String | optional | |
| `lyricsStatus` | String | optional | `"found"` \| `"notfound"` \| `"error"` (`IndexModels.swift:129`) — the ONLY gate for fetching `/lyrics/<id>.txt` |
| `appleMusicId` | String | optional | Apple catalog "adam id", bare numeric string e.g. `"1771724281"` (`IndexModels.swift:130-136`). On Android there is NO MusicKit — this is metadata/join-key only (Discover supersede), never a playback path (`docs/ARCHITECTURE-ANDROID.md:45-48`) |

**Nullability rule (load-bearing):** the pipeline emits `bpm/key/camelot` as
explicit JSON `null` until analyzed (`docs/architecture/03-catalog-and-data-model.md:51-52`).
Every optional field must decode from BOTH "key absent" and "key: null" to the
same Kotlin `null`. kotlinx.serialization: nullable types with defaults
(`val bpm: Double? = null`) + `Json { ignoreUnknownKeys = true; coerceInputValues = true }`.

**`beatsMs` is NOT in the catalog index** (verified: no such key in any of the
three documents). Per-beat grids live in the rips pipeline: the rips manifest
entry's `beatgrid` field is an S3 key of a lazy sidecar `rips/analysis/<id>.json`
(`docs/architecture/03-catalog-and-data-model.md:534-541`,
`apple/PocketDJ/State/RipsStore.swift:135`). Mix (Phase 3) concern — do not spec
it into the catalog decoder.

---

## 5. Multi-source model

- The user's source list is editable config: `SourceConfig { id, name, urlString, enabled }`
  (`apple/PocketDJ/Settings/SettingsStore.swift:92-99`); the default ships with
  exactly one source, `My Vinyl` → `current-index.json`
  (`SettingsStore.swift:560`). `Apple Music (Local)` and `My Digital` are added
  opt-in by name+URL (`SettingsStore.swift:316-343`); enabled sources yield
  `enabledSourceURLs` (`SettingsStore.swift:308`).
- **Each enabled source loads through its own cache-backed loader.** A source
  that fails (no cache + offline) is skipped and the others still render; the
  whole load fails only when EVERY source failed
  (`apple/PocketDJ/State/AppModel.swift:630-650`).
- **Merge = concatenate with first-occurrence-wins dedupe by id** across albums,
  songs, and playlists, in source-list order (`AppModel.swift:671-685`).
- **Provenance tags:** record `id → sourceName` for every album/song (first
  source that carries the id wins, same order as merge) plus the distinct source
  names in first-seen order — this drives the Browse source filter and per-row
  source badges (`AppModel.swift:655-667`). Source name for a document =
  `manifest.sourceName ?? "Collection"` (`AppModel.swift:661`).
- Playlists from each source are flattened into source-tagged rows, deduped by
  playlist id (`AppModel.swift:689-699`).
- iOS additionally appends two **synthetic local sources** AFTER all real ones —
  `"Discover"` (`apple/PocketDJ/State/DiscoverAddsStore.swift:21`) and
  `"Imported"` (`apple/PocketDJ/State/ImportedSongsStore.swift:31`) — so a real
  source always shadows a provisional twin (`AppModel.swift:207-250`). Phase 1
  Android has neither store; keep the merge order seam so they can slot in later.

---

## 6. Offline-first cache + refresh semantics (the iron behaviour)

Mirror `CatalogService` (`apple/PocketDJ/Services/CatalogService.swift`) exactly:

### Cache layout

- Directory: an app-private equivalent of iOS `Application Support/catalog-cache/`
  → Android: `context.filesDir/catalog-cache/` (`CatalogService.swift:69-80`).
  Do NOT use the HTTP cache: the index is tens of MB and URLCache-style caches
  refuse/evict it — the explicit file is the whole point
  (`CatalogService.swift:9-13`).
- One file per source URL: `<sha256-hex-of-url-string>.json` holding the **raw
  response bytes** (`CatalogService.swift:84-89`). The hash must be a stable
  algorithm (SHA-256 of `url.toString()`), never `hashCode()` (per-process
  iOS `Hasher` was explicitly rejected for the same reason,
  `CatalogService.swift:82-83`).
- Sibling validator file `<sha256>.meta.json` = `{ lastModified: String?, etag: String? }`
  (`CatalogService.swift:19`, `103-105`).
- Writes are **atomic** and best-effort (a cache-write failure never fails the
  load), and happen **only after a successful full decode** — never cache a
  partial/garbage body (`CatalogService.swift:50-56`, `94-100`).

### Load algorithm (per source URL)

(`CatalogService.swift:25-63`)

1. Build GET with 30s timeout, HTTP-cache bypassed; attach `If-Modified-Since`
   / `If-None-Match` from the stored validator when present. (OkHttp: set
   `cacheControl(CacheControl.FORCE_NETWORK)` equivalent + the two headers.)
2. `304` → return the decoded disk cache (it must exist — validators are only
   stored next to a cached body).
3. `2xx` → decode `IndexJSON`; on success write bytes + new
   `Last-Modified`/`ETag` to the cache, return fresh.
4. Non-2xx or any network error → **return the last-good disk cache instead of
   throwing**; throw only when there is no cache.

### App-level flow (mirror `AppModel.loadIfNeeded`, `AppModel.swift:132-193, 357-387`)

1. **Seed from disk first, no network wait**: decode every enabled source's
   cached file off the main thread, build the merged catalog, render it
   (`seedFromCache`, `AppModel.swift:169-193`). Show a loading state ONLY when
   nothing is cached (true first launch).
2. Then kick the **conditional refresh in a detached coroutine** (not on the
   caller's critical path — iOS learned this for cold-launch intents,
   `AppModel.swift:150-156`).
3. Refresh is **non-destructive**: a 304/offline/failed refresh can never blank
   an already-rendered catalog; surface an error state only when nothing was
   ever shown (`AppModel.swift:357-387`, esp. 382-386).
4. Single-flight guard: one load/refresh at a time (`AppModel.swift:137-142`).
5. Manual "Reload catalog" refreshes in place, never resets to loading
   (`AppModel.swift:612-624`).

---

## 7. Scale + decode strategy (do not get this wrong)

Live sizes (this worktree's `public/`, 2026-07-21):

| Document | Bytes | Albums | Songs | Playlists |
|---|---|---|---|---|
| `current-index.json` | 9,924,947 | 1,361 | 12,525 | — |
| `apple-music-index.json` | **32,736,962** | 11,436 | **93,185** | 117 |
| `digital-index.json` | 277,306 | 59 | 846 | 0 |

All three enabled ⇒ ~43 MB of JSON, ~12.8k albums / ~106k songs pre-dedupe.
iOS treats "~90k rows" as the design load (`AppModel.swift:146, 369`).

Requirements for the Android decoder:

1. **Stream-decode from the cache file** — `Json.decodeFromStream(inputStream)`
   (kotlinx-serialization-json-okio/jvm streaming entry point) on
   `Dispatchers.Default/IO`. Never read the 33 MB body into a `String` AND a
   DOM: no `JsonElement` tree for the full document.
2. **Decode straight into lean data classes** holding only the §3/§4 fields;
   `ignoreUnknownKeys = true` drops the heavy unmodelled subtrees (`pointer`,
   `enrichment`, `indexing`, `cloudReindex`) during parse, which is most of the
   vinyl document's bulk.
3. **All heavy work off the main thread** — decode, merge, source-tagging, sort,
   and browse-row precomputation happen in a background coroutine; hand the UI
   one immutable finished snapshot (iOS assigns the whole `Derived` value in one
   step precisely so a half-built catalog is never visible,
   `AppModel.swift:389-404, 522-535`).
4. **Index once, look up O(1)**: build `songsById` / `albumsById` hash maps at
   load (`AppModel.swift:463-464`); album→tracks resolves `trackList` through
   `songsById` (`AppModel.swift:702-704`).
5. Network responses decode the same way (OkHttp `response.body.byteStream()`);
   only persist bytes to cache after the decode succeeds. To avoid re-reading,
   iOS decodes from the in-memory body then writes it; on Android either buffer
   the body to a temp file and stream-decode from there, or accept one in-memory
   `ByteArray` of the body — never both a String copy and a tree.

---

## 8. What Phase 1 Browse actually needs

Browse rows are precomputed once per catalog build (`AppModel.swift:448-503`).
The per-kind rows and the fields they consume:

- **Album row**: `id`, `artist`, `name`, art candidates (`coverArtSources` +
  `coverArt`), `genre`, `year`, source tag. Sort: artist then name,
  case-insensitive (`AppModel.swift:456-461`).
- **Song row**: `id`, `artist`, `name`, resolved album name via `albumId`,
  source tag, genre **category** of the owning album
  (`Genre.category(album?.genre)`, `AppModel.swift:468-473`; mapping lives in
  `apple/PocketDJ/Support/Genre.swift:60`), plus filter/sort fields: `bpm`,
  `camelot`/`key`, `year`, `length`, `explicit`, `lyricsStatus`,
  `sentimentKeywords`.
- **Artist row**: derived by grouping the artist-sorted album list
  **case-insensitively** (one pass over consecutive albums; first album's casing
  is the display name) → `{ name, albumCount, songCount, artworkAlbumId }`
  (`AppModel.swift:478-499`).
- **Search**: one precomputed fold per item — fields joined with `\n`, folded
  case- AND diacritic-insensitively, matched with plain `contains`
  (`AppModel.swift:506-515`). Kotlin: `Normalizer.normalize(s, NFD)` strip
  combining marks + `lowercase(Locale.ROOT)`, precomputed in the same
  background build.
- **Source playlists** ("From your sources"): `IndexPlaylist` + source name
  (`AppModel.swift:689-699`) — name-ordered display.

NOT needed in Phase 1: `audioTracks` (Mix beat/analysis), `appleMusicId`
(no MusicKit; only future Discover-supersede), `country`, `keyStrength`,
`audioDurationSec`. Decode `audioTracks`/`appleMusicId` anyway (cheap, already in
the model) so later phases don't need a cache-schema change.

Playback reality check for Browse affordances: an Apple-Music-only track with no
public rip is **metadata-only** on Android (`docs/ARCHITECTURE-ANDROID.md:45-48`,
101-107) — Browse must not render a play affordance that can only fail.

---

## 9. Persistence iron law (applies to anything Android writes)

Any on-disk document Android defines (settings, cached derivations) must decode
leniently — optional fields with defaults, unknown keys ignored — so a later
field addition never wipes a saved doc. This is the ported iOS rule
(`docs/architecture/03-catalog-and-data-model.md:311-341`). The catalog cache
itself is exempt from migration concerns: it stores the server's raw bytes and
can always be discarded and refetched.
