# Android Phase 1 — Browse + Settings implementation contract

Source of truth: the iOS app under `apple/PocketDJ/` in this worktree. Every claim
below cites `file:line` in that tree. Where Android P1 deliberately cuts scope, the
cut is stated explicitly in §11. Locked platform decisions (Kotlin/Compose/Media3,
same CloudFront catalog, offline-first disk cache, no MusicKit/CloudKit) are in
`docs/ARCHITECTURE-ANDROID.md:21-58` and are not restated here.

Iron law (ported from iOS): **every on-disk document decodes leniently** — all
non-identity fields optional with defaults, unknown fields ignored, so a later
field addition never wipes a saved doc. iOS models this everywhere
(`Models/IndexModels.swift:4-5`, `Settings/SettingsStore.swift:488-557`,
`Browse/BrowseState.swift:107-111`). Android must use
`kotlinx.serialization` with `ignoreUnknownKeys = true` and nullable-with-default
fields on every persisted/remote document in this spec.

---

## 1. Endpoints (all verified in code)

| What | URL | Cite |
|---|---|---|
| Catalog base (prod) | `https://d2p4cubg6se03u.cloudfront.net` | `Support/Config.swift:17` |
| Catalog base (dev) | `https://djictbz9w796r.cloudfront.net` | `Support/Config.swift:16` |
| Default source "My Vinyl" index | `<catalogBase>/current-index.json` | `Support/Config.swift:36`, seeded as the only default source `Settings/SettingsStore.swift:560` |
| "Apple Music (Local)" index (opt-in) | `<catalogBase>/apple-music-index.json`, source name `"Apple Music (Local)"` | `Support/Config.swift:39-40` |
| "My Digital" index (opt-in) | `<catalogBase>/digital-index.json`, source name `"My Digital"` | `Support/Config.swift:45-46` |
| Online-search host config | `<catalogBase>/search-config.json` → `{ host?, region?, index? }`, all optional, non-empty overlays only | `Support/Config.swift:75`, `Services/Search/SearchService.swift:57,85-96` |
| Online search | `POST https://<host>/<index>/_search` — **direct to the aoss host, SigV4-signed; no proxy** | `Services/Search/SearchService.swift:120-155` |
| aoss baked defaults | host `mii9dwge3uiee2tvivt5.aoss.us-west-2.on.aws`, region `us-west-2`, index `pocketdj`, service `"aoss"` | `Services/Search/SearchService.swift:51-53,107` |
| Public rips bucket | `https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com` | `Support/Config.swift:22` |
| Rips manifest | `<ripsBase>/rips/manifest.json` → `{ "<songId>": ManifestEntry }` | `State/RipsStore.swift:259,264-273` |
| Song audio | `<ripsBase>/<entry.key>` (key is e.g. `rips/<songId>.mp3`) | `State/RipsStore.swift:292-295` |
| Album art | root-relative `/art/…` resolved against `catalogBase`; absolute URLs (iTunes `mzstatic`) used as-is | `Support/Config.swift:89-94` |
| Rip server health | `GET <ripServerURL>/health` w/ optional token (Settings "Test connection") | `Views/SettingsView.swift:676-692`, `Services/RipServerService.swift` |

The CloudFront **proxy** path (`proxyBase: '/pocketdj'`) exists ONLY in the PWA as a
CORS workaround (`src/search/esClient.ts:19-22`, `src/search/sigv4.ts:5-7`). Native
clients skip it and hit the aoss host directly (`Services/Search/SigV4.swift:10-11`).
Android does the same — sign for and send to the real host.

Android P1 ships pointed at **prod** catalogBase (`Support/Config.swift:11`).

---

## 2. Catalog documents

### 2.1 Index JSON (`Models/IndexModels.swift:6-150`)

```
IndexJSON      { manifest, albums: [IndexAlbum], songs: [IndexSong], playlists: [IndexPlaylist]? }
Manifest       { source?, generatedAt?, sourceName?, counts? { albums?, songs? } }   (:51-61)
IndexPlaylist  { id, name, songIds: [String] }                                        (:25-29)
ArtSource      { type: "cdn"|"remote", url, cors? }                                   (:63-67)
AudioTrack     { trackNumber?, startMs?, endMs?, durationMs?, bpm?, key?, camelot?, keyStrength? } (:70-79)
IndexAlbum     { id, artist, name, coverArt?, coverArtSources?, genre?, year?, country?,
                 trackList: [String], fileType?, audioTracks?, audioDurationSec?, appleMusicId? } (:81-99)
IndexSong      { id, albumId?, artist, name, trackNumber?, year?, sentimentKeywords?,
                 explicit?, bpm?, key?, camelot?, length?, fileType?, lyricsStatus?, appleMusicId? } (:115-136)
```

Non-negotiables:
- `length` is **milliseconds** (`IndexModels.swift:127`). Display as `m:ss`
  (`Support/Format.swift:5-9`); BPM displays as a rounded Int; both show `–` when
  absent/zero (`Support/Format.swift:11-14`).
- **`IndexSong` has NO genre field.** A song's genre is derived from its owning
  album at construction time via `Genre.category(album.genre)`
  (`State/AppModel.swift:468-473`, `Browse/BrowseModel.swift:28-33`).
- Cover-art candidate order: every `coverArtSources[].url` first (CDN thumbs),
  then `coverArt` as backup (`IndexModels.swift:105-112`). Try in order in Coil.
- Unknown fields ignored; only `id/artist/name` (+ `trackList` on albums) are
  required (`IndexModels.swift:4-5`).

### 2.2 Offline-first disk cache (`Services/CatalogService.swift`)

Per-source-URL explicit file cache — do NOT rely on OkHttp's HTTP cache (iOS
learned this: URLCache silently refuses bodies over its capacity, `:9-13`):

1. Cache file name = SHA-256 hex of the source URL string, under an app-files
   `catalog-cache/` dir (`:69-89`). Sibling `<sha>.meta.json` holds
   `{ lastModified?, etag? }` (`:103-105`).
2. Load = conditional GET with `If-Modified-Since`/`If-None-Match` (`:32-35`);
   `304` → serve cached bytes (`:43-45`); `2xx` → decode, then persist raw bytes +
   validators **only after a successful decode** (`:50-55`), atomic write (`:94-99`).
3. **Any** network/decode failure → serve last-good cache; throw only when no
   cache exists (`:57-62`).
4. Startup UX (AppModel doctrine): seed/render from disk cache instantly, refresh
   in place, never blank a loaded catalog on a failed refresh
   (`State/AppModel.swift:382-386,612-624`).

### 2.3 Multi-source merge + source tags (`State/AppModel.swift:626-699`)

- Fetch every **enabled** source's index; a source that fails with no cache is
  **skipped**; the whole load fails only when every source failed (`:630-650`).
- Merge: iterate sources in Settings order, **first occurrence of each id wins**
  for albums, songs, and playlists (`:671-685`).
- Source tag: each album/song id → the `manifest.sourceName ?? "Collection"` of
  the FIRST source carrying it; `availableSources` = distinct names, first-seen
  order (`:653-667`). These names feed the sources rail + the `source` filter
  field and the per-item source badge.
- Effective albums list is sorted artist → name, case-insensitive
  (`:456-461`); songs stay in catalog order.

---

## 3. Browse rows (`Browse/BrowseModel.swift`)

Kinds: `album`, `song`, `artist` (`:6`). Rows (`:26-62`):
- `album(IndexAlbum, source?)`
- `song(IndexSong, albumName, source?, genre?)` — genre = collapsed tier-1
  category of the owning album (see §5 Genre).
- `artist(name, albumCount, songCount, artworkAlbumId?)` — built by a single pass
  over the artist-sorted album list, **grouped case-insensitively** (so
  "OutKast"/"Outkast" merge; first album's casing is the display name); songCount
  = sum of the grouped albums' `trackList.count`; row id `"artist:<name>"`
  (`State/AppModel.swift:478-499`, `Browse/BrowseModel.swift:44`).

Row visuals (match, dark theme, accent `#6EA8FF`):
- Album grid card: square cover, name, artist, genre tag + year
  (`Views/BrowseView.swift:742-757`); adaptive grid, min cell 150dp
  (`Views/BrowseView.swift:51`). Album list row: 52dp cover, name/artist, genre
  tag, year (`Views/BrowseView.swift:759-777`).
- Song row: thumbnail + title (+ `E` explicit badge) + artist/album + BPM +
  key chip + duration + play/download transport (shared row —
  `Views/BrowseView.swift:779-795`).
- Artist row: representative-album thumb + name + "N albums · M songs"
  (`Views/BrowseView.swift:801-824`).
- Results header: "`<count>` albums|songs|artists" + active-sort summary
  (`Views/BrowseView.swift:554-576`).

---

## 4. Search

### 4.1 On-device text search (`State/AppModel.swift:506-515`, `Browse/BrowseState.swift:383-397`)

- Precompute one **search key per row**, parallel to the row array:
  fields joined with `"\n"`, folded case- AND diacritic-insensitively,
  locale-independent. Albums: `name\nartist\ngenre` (`AppModel.swift:467`);
  songs: `name\nartist\nalbumName` (`AppModel.swift:474-477`); artists: `name`
  (`AppModel.swift:497`).
- Match: fold the query the same way, **strip `\n` from the query** (else a
  newline matches across field boundaries), then plain `contains` per key
  (`BrowseState.swift:388-395`). Kotlin: fold = NFD-normalize, strip combining
  marks, lowercase.
- Pipeline order: base rows → text query → filter clauses → multi-key sort
  (`BrowseState.swift:383-397`).
- Run the filter+sort **off the main thread**, memoized by a deterministic
  signature of (catalogRevision, kind, query, complete clauses, sortKeys) — iOS
  JSON-encodes with sorted keys to make the memo key unambiguous
  (`BrowseState.swift:148-166,226-250`); ~90k rows re-sorted on the UI thread was
  a shipped runloop-hang bug. Debounce typing ~180 ms (`BrowseState.swift:236`).
- Incremental rendering: hand the list a growing prefix — page size 120, grow by
  a page when the last rendered row appears, reset to one page whenever the
  result-set signature changes (`BrowseState.swift:430-463`,
  `Views/BrowseView.swift:44-70,626-635`). LazyColumn/LazyVerticalGrid still need
  this on a 90k-row set (keying/diffing cost), so keep it.

### 4.2 Online (aoss) search

Request (`Services/Search/SearchService.swift:117-172`):
- `POST https://<host>/<index>/_search`, JSON body, timeout 15 s.
- Query: empty → `match_all`; else
  `multi_match { query, fields: ["title^3","artist^2","album^1.5","lyrics","sentiment^2"], type: "best_fields", fuzziness: "AUTO", operator: "and" }` (`:123-131`).
- `filter` always includes `{"term":{"type":"album"|"song"}}` for the current
  kind (`:134`); every complete filter clause is translated too (§6.3).
- `"track_total_hits": true`, `from`/`size` paging (`:148-152`).
- `sort`: each SortKey → `{"<docField>":{"order":"asc"|"desc"}}` using the
  sort-field map (`:184-199` — text fields use `.kw` keyword subfields, `name` →
  `title.kw`, `genre` → `genreCategory`), **always ending with
  `{"id":{"order":"asc"}}`** so offset paging never duplicates/skips (`:209-221`).
- Signing: AWS SigV4, service `"aoss"`, signed headers exactly
  `host;x-amz-content-sha256;x-amz-date`, empty canonical query string, payload
  SHA-256; emit `x-amz-date`, `x-amz-content-sha256`, `Content-Type:
  application/json`, `Authorization` (`Services/Search/SigV4.swift:27-64`).
  Credentials = user-entered read-only key/secret from Settings
  (`Views/BrowseView.swift:376-380`).
- Host resolution order: user override (Settings host field, normalized to a bare
  host — strip scheme + path) → `search-config.json` → baked default
  (`SearchService.swift:61-96`). Fetch the config once per process, memoized;
  failures keep baked defaults.

Response (`SearchService.swift:225-254`): `hits.total.value` (exact, because
`track_total_hits`) + `hits.hits[]` of `{ _id, _source: { type?, title?, artist?,
album?, albumId?, genre?, year?, trackNumber?, bpm?, explicit?, key?, camelot?,
source? } }`.

Paging model (`State/OnlineSearchModel.swift`): page size 50 (`:43`); debounce
300 ms (`:73`); every query/kind/filter/**sort** change resets and reloads page 1
(`:59-76`); `loadMore()` fetches `from = loadedCount`, appends, self-guards on
`hasMore && !isLoadingPage` (`:121-138`); advance the offset by the page's RAW
hit count even when de-dupe drops rows (`:142-147`); hard cap `from+size ≤ 10_000`
(OpenSearch `max_result_window`, `SearchService.swift:113-115`,
`OnlineSearchModel.swift:50-52`). Map each hit to the full catalog item when the
id is in the local catalog (art etc.), else build a stub row from the hit's own
fields (`:150-169`). No creds configured → failed state with "Add OpenSearch
credentials in Settings to search online." (`:66-69`).

Mode toggle: a toolbar button cycles device ↔ online; online applies to album +
song kinds only — the artist kind is always on-device
(`Views/BrowseView.swift:152-153,422-441`). Persist the mode with the browse
snapshot (§7). A transient page error keeps already-loaded rows
(`OnlineSearchModel.swift:135-137`).

---

## 5. Genre + Camelot (must be ported exactly)

- `Genre.category(raw)` — ordered substring matcher over 14 tier-1 categories
  ("hip-hop" first … "pop" last, `"Other"` fallback); lowercase+trim the raw
  genre, first category with ANY keyword substring-hit wins. Port the keyword
  table verbatim from `Support/Genre.swift:16-74`. Used for: song-row genre,
  the genre filter/sort value for BOTH kinds (`Browse/BrowseModel.swift:116-117,
  169-171,181-183`), and the genre options-list ordering
  (`Support/Genre.swift:77-79`, `Browse/BrowseState.swift:414-415`).
- Online parity: the indexed doc's `genreCategory` keyword is the same collapsed
  category — genre filters/sorts target it (`SearchService.swift:188,281`).
- `Camelot`: code `"<1-12><A|B>"`; rank = `num*2 + (major?1:0)` for wheel-order
  sort (`Support/Format.swift:24-41`); chip color = HSL(hue=(num-1)/12, s 0.68,
  l 0.50 major / 0.38 minor) (`Support/Format.swift:43-52`). Key chip renders
  key + camelot code with that color (`Views/KeyChip.swift`).

---

## 6. Filters + sort

### 6.1 Field registry (`Browse/BrowseModel.swift:100-149`)

| id | label | kind | ops | options-backed | applies to |
|---|---|---|---|---|---|
| artist | Artist | string | eq, neq, inList | no | album, song, artist |
| albumCount / songCount | Albums / Songs | number | eq, neq, between | no | artist |
| name | Title | string | eq, neq, inList | no | album, song |
| year | Year | number | eq, neq, inList, between | no | album, song |
| genre | Genre | string | eq, neq, inList, **notInList** | yes | album, song |
| fileType | File type | string | eq, neq, inList | yes | album, song |
| source | Source | string | eq, neq, inList | yes | album, song |
| country | Country | string | eq, neq, inList | yes | album |
| trackCount | Track count | number | eq, neq, inList, between | no | album |
| trackNumber | Track # | number | eq, neq, inList, between | no | song |
| length | Length | number | eq, neq, inList, between | no | song |
| bpm | BPM | number | eq, neq, inList, between | no | song |
| key | Key | string | eq, neq, inList | yes | song |
| camelot | Key (Camelot) | string | eq, neq, inList | yes | song |
| explicit | Explicit | bool | eq | no | song |
| sentiment | Sentiment | stringArray | inList, eq, neq | yes | song |

All sortable except `sentiment` (`:142-143`). Op labels: is / is not / any of /
none of / between (`:65-74`).

Clause = `{ id, field, op, value: String, values: Set<String>, min?, max? }`;
incomplete (no-op) when eq/neq has empty value+values, inList/notInList has empty
values, between has neither bound (`:208-224`).

Options for an options-backed field = distinct non-empty values over the current
kind's base rows; `source` uses `availableSources` directly; sort: camelot by
wheel rank, genre by category priority order, else case-insensitive alpha
(`Browse/BrowseState.swift:399-419`).

### 6.2 Local filter semantics (`Browse/BrowseModel.swift:228-279`)

Clauses AND-compose (`:275-278`). Normalization for strings: trim + lowercase
(`:226`). Per kind:
- string: eq/neq compare normalized; inList membership; **notInList keeps rows
  whose value is absent/empty** (an ungenred song survives a genre none-of, `:269`).
- number: eq exact; **neq keeps missing** (`:252`); inList/notInList on parsed
  doubles; between inclusive with open ends (−∞/+∞ for a missing bound), missing
  value fails between (`:256-258`).
- bool (`explicit`): eq against `"true"`/`"false"`; missing → false (`:244-246`,
  `:189`).
- stringArray (`sentiment`): inList = any selected keyword present; eq/neq =
  contains / not-contains one keyword (`:236-243`).
- A clause whose field doesn't apply to the row's kind passes the row (`:232`).

### 6.3 Online filter translation (`Services/Search/SearchService.swift:272-352`)

Field id → doc field map at `:276-292` (text → `.kw` subfields, `name` →
`title.kw`, `genre` → `genreCategory`, `sentiment` → `sentiment.kw`). eq →
`term`, neq → `must_not term`, inList → `terms`, notInList → `must_not terms`,
between → `range {gte,lte}`. String values lowercased+trimmed (the index uses a
lowercase normalizer, `:326-338`); whole numbers emitted as Int (`:344-346`);
explicit eq → boolean term (`:300-303`).

### 6.4 Sort engine (`Browse/BrowseModel.swift:283-351`)

Multi-key, **stable** (input index is the final tiebreak, `:299,324`), **nulls
last regardless of direction** (`:314-317`); null = missing value OR empty
string (`:329-335`). camelot sorts by wheel rank as a number (`:293-303`);
strings compare case-insensitively (`:346-350`); bools false<true. No sort keys
→ catalog order (albums: artist › title; the sheet's empty-state copy says so,
`Views/SortSheet.swift:16-17`).

### 6.5 Filter/sort UI (P1 shape)

- Filter sheet: list of clause editors (field picker → op picker → value editor:
  toggle for bool, min–max pair for between, multi-select checklist for
  options-backed inList/notInList, comma-separated text for free-text inList,
  dropdown for options-backed eq/neq, plain/numeric text otherwise) + "Add
  filter" + per-clause remove + "Clear All" (`Views/FilterSheet.swift:24-165`).
  Changing a clause's field resets op to the field's first op and clears values
  (`:96-103`).
- Sort sheet: ordered key list (top = primary), per-key asc/desc toggle,
  drag-reorder, swipe/delete, "Add key" from unused sortable fields, "Clear All"
  (`Views/SortSheet.swift:12-66`).
- Toolbar: filter icon fills when `activeFilterCount > 0` (complete clauses
  only, `Browse/BrowseState.swift:126-128`, `Views/BrowseView.swift:456-462`);
  album kind gets a grid/list layout toggle (`Views/BrowseView.swift:446-453`).
- **P1 filter cut:** ship the sheet with the field registry restricted to
  `genre`, `bpm`, `key` (+`camelot`), `source` (task-locked cut). Keep the
  registry/engine full-width internally (it is the same engine History and
  later phases reuse); hiding a field is a UI filter on `Fields.forKind`.

---

## 7. Browse state persistence

Persisted snapshot: `{ kind, clauses, sortKeys, layout, searchMode }` under one
key (iOS: UserDefaults `"pdj.browse.v1"`, `Browse/BrowseState.swift:92-119`).
`searchMode` ∈ device|online (discover excluded on Android). Restore on launch;
persist on every kind/layout/clauses/sortKeys/searchMode change
(`Views/BrowseView.swift:105-118`). **Transient (never persisted): the query
text** (`BrowseState.swift:13`), membership + favorite filters (`:40-68`).
Android: a small JSON doc in DataStore, decoded leniently (unknown keys ignored,
missing fields defaulted) per the iron law.

---

## 8. Album detail (`Views/AlbumDetailView.swift`)

- Resolve the latest album by id from the catalog on every render (`:22`).
- Header: cover 168dp, name, artist (accent), genre/year/country tags, source
  tag (`app.source(ofAlbum:)`), "`N` tracks" (`:90-117`).
- Track table: tracks = `album.trackList.compactMap { songsById[it] }` — **order
  comes from `trackList`, ids not in the catalog are silently dropped**
  (`State/AppModel.swift:702-704`). Columns: `#` (trackNumber ?? position),
  Title (+ `E` badge when `explicit == true`, + up to 3 sentiment keywords as a
  caption), BPM, Key chip (key + camelot), Time (`m:ss`), then the play control
  (`:191-266`). Zebra-striped rows; row tap → song detail (`:122-131`).
- Audio-analysis section (analog albums, `hasAudioAnalysis`): per-segment rows
  `# · startMs–endMs · bpm · key chip · keyStrength%` + total duration
  (`:143-189`, `Models/IndexModels.swift:70-79,101`). **P1: render read-only if
  cheap, else defer** — it is display-only either way (editing is deferred, §11).
- Deferred from this screen in P1: Play/Shuffle-whole-album (needs the Now
  Playing setlist engine, `:78-88`), Stemify, Add-to-collection, Edit (`:45-71`).

## 9. Song detail (`Views/SongDetailView.swift`)

P1 = a detail sheet/screen with:
- Album art 220dp centered (`:34-40`), title, artist, key chip, source tag,
  album row that navigates to the album (`:138-174`; iOS routes artist/album
  hotlinks through a pending-route seam — Android can navigate directly).
- Metadata grid, rows in this order, skipping absent values: Artist, Album,
  Track #, Year, BPM (always, `–` when absent), Key, Camelot, Length (always),
  Explicit ("Yes"/"No"), File type (uppercased), Source, Lyrics status
  (`:177-192`).
- Sentiment keyword chips when present (`:194-199`).
- Play action row (same play affordance as list rows) (`:219-244`).
- Deferred: lyrics body fetch, stem audition, Apple Music library affordance,
  Edit, Add-to-collection (`:66-135`, §11).

## 10. Playback resolution (P1, Browse's play affordance)

A Browse/track row is **playable iff the rips manifest has its songId**:
1. On launch (and pull-refresh) fetch `<ripsBase>/rips/manifest.json`, decoded
   as `Map<String, ManifestEntry>`; offline → keep the previous manifest
   (`State/RipsStore.swift:259-273`). Entry fields Android P1 needs: `key`
   (required), `startMs?`, `durationMs?`, `bpm?`, `camelot?` — everything else
   optional/ignored, lenient decode (`:88-141`).
2. Play URL = `ripsBase + "/" + entry.key` (`:292-295`). **Honor `startMs`**:
   analog (vinyl) songs share ONE album mp3 per side — the entry's `key` points
   at the album file and `startMs` is the song's offset; seek there on play, and
   treat `startMs + durationMs` as the song's end (`:104-107,159-170`). Digital
   songs are per-song files (`startMs` nil).
3. No manifest entry + a configured rip server → rip-on-demand exists on iOS
   (`:190-197` and below); **P1 may defer rip-on-demand** and show the row as
   metadata-only (architecture doc's sources-reality rule,
   `docs/ARCHITECTURE-ANDROID.md:46-49`). If deferred, the play control is
   simply absent/disabled for unmanifested songs.
4. Media3/ExoPlayer + MediaSession per locked decision 4.

## 11. Explicitly DEFERRED from Android P1 Browse

Present in iOS Browse but out of P1 scope (record, don't build):
- **Discover** tab (full-Apple-Music search via the rip server + MusicKit)
  (`Views/BrowseView.swift:78-87,155-212`, `Views/BrowseDiscover.swift`) — no
  MusicKit on Android.
- **Shazam** recognizer row (`Views/BrowseView.swift:230-241`).
- **Star map** — PWA-only, no port planned (`docs/ARCHITECTURE-ANDROID.md:112-113`).
- **Edits** (EditAlbum/EditSong/EditAudioAnalysis + edits export/import overlay)
  (`Views/AlbumDetailView.swift:73-75`, `Views/SettingsView.swift:282-296`).
- **Rip/burn/stemify management** (row download ⤓, Stemify, burns, storage
  manager) (`Views/AlbumDetailView.swift:58-65`, `Views/SettingsView.swift:115-128`).
- **Collection-membership filter** + **favorites filter** + Add-to-collection
  (need Phase 2 collections / favorites stores)
  (`Views/FilterSheet.swift:57-63,221-313`, `Browse/BrowseState.swift:40-68`).
- **History mode** of the browse pipeline (`Browse/BrowseState.swift:76-88`) —
  History is Phase 1 scope overall but is a separate spec, not this one.
- **Artists kind** — cheap (one grouping pass, §3) and allowed, but not required
  for the P1 checkpoint; the P1 rail is Albums grid + Songs list.
- Keyboard navigation / shortcuts (macOS affordances,
  `Views/BrowseView.swift:471-509`).

**P1 Browse surface (the build target):** sources rail (chips: "All" + one per
`availableSources`, implemented as a `source` `eq` clause) → Albums grid /
Songs list toggle → search field (on-device match; online aoss toggle when creds
configured) → filter sheet (genre/bpm/key/source) + sort sheet → album detail
with playable track rows → song detail (art, metadata grid, bpm/key chip, play).

## 12. Settings — Android P1 rows

From `Views/SettingsView.swift`, keep for P1:

1. **Data sources** (`:300-360`): editable list of `{ name, indexURL, enabled }`
   rows + remove; "Add source"; one-tap loaders for "Apple Music (Local)" and
   "My Digital" (hidden once present — match by name OR url,
   `Settings/SettingsStore.swift:316-343`); **"Reload catalog"** button that
   persists, evicts any HTTP-layer cache for enabled source URLs, and refetches
   (`:342-354`). Default seed: one source, "My Vinyl" → `current-index.json`,
   enabled (`SettingsStore.swift:560`).
2. **Online search** (`:366-410`): Access key ID, Secret access key
   (secure/masked), optional "Search host" override (blank = shared default),
   live "Currently searching: <effective host>" line, Save / Clear, "Configured"
   badge when key+secret non-empty (`SettingsStore.swift:309`). The host field
   feeds the SearchConfig override (§4.2). Store the secret in
   EncryptedSharedPreferences/Keystore, not plaintext DataStore.
3. **Import (rip) server** (`:510-567`): server URL + optional token + "Test
   connection" (GET `/health`, shows songs/version/HLS or Timed out/Unreachable,
   `:676-692`). **Default URL is BLANK — never ship a baked hostname**; all
   server-gated affordances stay dormant until set
   (`Support/Config.swift:24-33`, `SettingsStore.swift:243-250,562-566`).
   Skip the "Rip from cloud source" toggle (iOS marks it delete-pending,
   `:522-536`).
4. **Reset all app state** (`:702-728`): confirm dialog → clear the settings
   doc, clear the catalog disk cache directory, clear HTTP caches, reload
   (`SettingsStore.swift:426-471`). This is P1's "cache/storage clear".

Settings persistence: one JSON blob (iOS key `"pdj.settings.v1"`,
`SettingsStore.swift:229-306`) — every later-added field optional with a
default, a failed field never resets the blob (`SettingsStore.swift:488-557` is
the pattern to copy). Android P1 fields: `sources`, `ripServerURL`, `ripToken`,
`searchAccessKeyID`, `searchSecretKey`, `searchEndpoint` (+ the browse snapshot
of §7 stored separately).

Deferred Settings sections: Profile/iCloud sync, Streaming (MusicKit), Jukebox
(separate P1 spec), Mix, Sync, Storage manager, Edits, Backup, Debug
(`:48-63` enumerates them all).

---

## 13. Non-obvious correctness notes (all bit iOS first)

- Filter/sort/search of the full catalog must run off the UI thread with a
  memo + debounce; the naive per-keystroke locale-aware search over ~90k rows
  was a multi-second main-thread hang (`Browse/BrowseState.swift:30-34,383-386`).
- A changed result set must never render the previous set's large paging prefix
  for even one frame — derive the visible budget from the result-set signature
  instead of resetting it after the fact (`Views/BrowseView.swift:53-70`).
- Online paging: reset on sort change too (server sorts; the client can't
  reorder loaded pages) (`Views/BrowseView.swift:108-110`).
- The song-list paging trigger must sit on a row that always renders
  (`Views/BrowseView.swift:699-705`).
- Never cache a catalog response before it decodes (`CatalogService.swift:51-53`).
