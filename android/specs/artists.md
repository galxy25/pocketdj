# Artists browse — Android implementation contract

**Audience:** an engineer adding the **Artists** browse kind to the existing Android
Browse surface, who has read `specs/browse.md` and `specs/realize-play.md` but not the
Swift/SDK internals. Every claim cites its source of truth by `file:line` — iOS under
`apple/PocketDJ/…`, existing Android under
`android/app/src/main/java/com/levi/pocketdj/…` (abbreviated `…/screens/browse/…`).

This is an **additive slice on top of a shipped, merged Browse** (`specs/browse.md`
§3/§11 already reserved the Artists kind as "cheap and allowed, not required for the
P1 checkpoint"). It reuses the existing off-main filter/search pipeline, the
`BrowseSession` persistence, the `CollectionsStore.playNow` reserved Now Playing
setlist (P2, already merged), and the setlist-autoplay navigation funnel — it invents
**one new precomputed row list, one new detail screen, and one new nav route.**

Iron law (unchanged, `specs/browse.md:9-15`): the one persisted document this slice
touches — `BrowseSnapshot` — already decodes leniently via `PdjJson`; adding
`"artists"` as a `kind` value must not change its shape, and an unknown `kind` string
must keep falling to the safe default.

---

## 1. Source of truth

| Concern | iOS | existing Android |
|---|---|---|
| Artists as a browse kind/tab | `Views/BrowseView.swift:196-206` (`ShowTab.artist`), `Browse/BrowseModel.swift:6` (`ItemKind.artist`) | `…/screens/browse/BrowseModels.kt:19` (`enum BrowseKind`) |
| Artist-row derivation (grouping) | `State/AppModel.swift:478-499` (`buildEffective`) | `…/screens/browse/BrowseModels.kt:97-142` (`BrowseRows`) |
| Artist row visuals | `Views/BrowseView.swift:801-824` (`ArtistRow`) | `…/screens/browse/BrowseScreen.kt` (row composables), `BrowseComponents.kt` (`AlbumArt`) |
| Search key = artist name only | `State/AppModel.swift:497` (`searchKey(artist)`) | `…/screens/browse/BrowseModels.kt:104,115` (`Fmt.fold`) |
| Artist detail (albums + Play/Shuffle) | `Views/ArtistDetailView.swift` (whole file) | new `…/screens/browse/ArtistDetailScreen.kt` |
| ▶/🔀 whole-discography play | `Views/ArtistDetailView.swift:78-85` → `CollectionsStore.playNow(…source:.artist…)` | `…/data/collections/CollectionsStore.kt:1141-1187` (`playNow`) |
| Play-context token `artist` | `PocketDJApp.swift:381-399`, `CollectionsStore.swift:1237-1249` | `…/playback/PlayEvents.kt:29,51-52` (`PlayContext.artist` / `SOURCE_ARTIST`) — **already present** |
| Setlist-autoplay funnel | `ArtistDetailView.swift:81-84` (`SetlistLaunch`) | `…/screens/playlists/SetlistDetailScreen.kt:113-140` (`autoplay` → `start()`); route `…/MainActivity.kt:251-267` |
| Kind persistence | `Browse/BrowseState.swift:92-119` | `…/screens/browse/BrowseSessionPersistence.kt:56-57` (`parseKind`), `…/data/settings/BrowseSnapshot.kt:17` |
| Sortable-field registry | `Browse/BrowseModel.swift:100-149` | `…/screens/browse/BrowseSort.kt:12-31` (`SortField`) |

Locked platform decisions (Kotlin/Compose/Media3, no MusicKit/CloudKit,
offline-first catalog) are in `docs/ARCHITECTURE-ANDROID.md:21-58` and not restated.

---

## 2. The Artists kind (toggle + enum)

### 2.1 Enum + toggle

Add `ARTISTS` to `BrowseKind` (`BrowseModels.kt:19`), yielding
`ALBUMS | SONGS | ARTISTS`. iOS orders the tabs Album, Song, Artist
(`BrowseView.swift` `ShowTab` order); match: `enum class BrowseKind { ALBUMS, SONGS,
ARTISTS }`. The existing `SingleChoiceSegmentedButtonRow` in
`BrowseScreen.kt:278-288` iterates `BrowseKind.entries`, so a third segment appears
automatically once the label branch is extended:

```
Text(when (entry) {
    BrowseKind.ALBUMS -> "Albums"; BrowseKind.SONGS -> "Songs"; BrowseKind.ARTISTS -> "Artists"
})
```

The search-field placeholder (`BrowseScreen.kt:339`) and the results-header noun
(`BrowseScreen.kt:360-362`) both branch on kind today; extend both with the
`ARTISTS → "Search artists"` / `"artists"` arm. iOS parity: `kindNoun` returns
`"artists"` (`BrowseView.swift:552`).

The album layout (grid/list) toggle is shown **only** when `kind == ALBUMS`
(`BrowseScreen.kt:289`) — leave that gate as-is; Artists is always a list.

### 2.2 Persistence (lenient, additive)

`BrowseSnapshot.kind` is a lowercased enum-name string (`BrowseSnapshot.kt:17`,
default `"albums"`; written via `BrowseSessionState.toSnapshot` at
`BrowseSessionPersistence.kt:23-24` as `kind.name.lowercase()`). `parseKind`
(`BrowseSessionPersistence.kt:56-57`) currently maps only `"songs"` → SONGS, else
ALBUMS. Extend it to recognize `"artists"` → ARTISTS, keeping the `else → ALBUMS`
fallback so an unknown/older/newer string is still safe (iron law). **No `BrowseSnapshot`
field is added** — the value space of an existing field widens, which a lenient
decode already tolerates; a doc written by the old build (no `"artists"`) still
restores fine, and a doc written by this build read back by the old build falls to
ALBUMS instead of crashing. This is the whole persistence change.

`BrowseSession.kind` (`BrowseModels.kt:168`) is already a `MutableStateFlow<BrowseKind>`
persisted through the debounced `attach` combine (`BrowseModels.kt:194-211`) — no
change; ARTISTS rides the existing flow.

---

## 3. Deriving the artist list (`BrowseRows.artistRows`)

Add a precomputed `artistRows: List<ArtistRow>` to `BrowseRows` (`BrowseModels.kt:97`)
so it is built **once per catalog off the main thread** alongside `albumRows`/`songRows`
(the identity-keyed memo `BrowseRows.of`, `BrowseModels.kt:133-141`, already guarantees
this). Grouping must reproduce `AppModel.buildEffective` (`AppModel.swift:478-499`)
bit-for-bit:

### 3.1 Row shape

```kotlin
data class ArtistRow(
    val name: String,        // display name = FIRST album's casing in the group
    val albumCount: Int,
    val songCount: Int,      // Σ over grouped albums of album.trackList.size
    val artworkAlbumId: String?, // FIRST album's id — the representative art
    val searchKey: String,   // Fmt.fold(name) — artist name ONLY (iOS AppModel.swift:497)
)
```

iOS row id is `"artist:<name>"` (`BrowseModel.swift:44`); Android keys the LazyColumn
by `name` (unique after case-insensitive grouping — see the guard below), so no id
field is needed. Match iOS field derivation exactly:
`.artist(name:, albumCount: j-i, songCount:, artworkAlbumId: albums[i].id)`
(`AppModel.swift:493-494`).

### 3.2 Grouping algorithm (single pass, order-preserving)

`catalog.albums` is already sorted **artist › name, case-insensitively**
(`MergedCatalog.kt:98-101`; `AppModel.swift:456-461`), so consecutive same-artist
albums are adjacent and one linear pass groups them **without a dictionary**
(`AppModel.swift:483-499`):

1. `i = 0`; while `i < albums.size`:
2. `artist = albums[i].artist` (the group's first album — its casing is the display
   name, `AppModel.swift:493`).
3. Advance `j` from `i` while `albums[j].artist.equals(artist, ignoreCase = true)`,
   accumulating `songCount += albums[j].trackList.size`.
4. Emit `ArtistRow(name = artist, albumCount = j - i, songCount, artworkAlbumId =
   albums[i].id, searchKey = Fmt.fold(artist))`; set `i = j`.

**Non-negotiables (each a shipped iOS decision — copy exactly):**

- **Case-INSENSITIVE grouping** (`AppModel.swift:487-491`,
  `String.CASE_INSENSITIVE_ORDER` on the Kotlin sort). A merged catalog whose sources
  disagree on casing ("OutKast" vs "Outkast") sorts the albums adjacent; grouping
  case-insensitively fuses them into ONE row (else you'd emit two rows with a duplicate
  key → a LazyColumn crash). Kotlin: `equals(artist, ignoreCase = true)` (ASCII+Unicode
  simple case fold — matches `localizedCaseInsensitiveCompare == .orderedSame` for the
  data here; the sort already used `String.CASE_INSENSITIVE_ORDER`, so grouping must use
  the same predicate to stay consistent).
- **`songCount` counts `trackList.size`, NOT resolved tracks** (`AppModel.swift:489`) —
  it includes ids absent from the catalog and any repeated ids. This is intentional
  parity with the header count in §4 (which is `flatMap(trackList).size` = the same
  number). Do **not** use `MergedCatalog.tracks(...)` (which drops missing/duplicate
  ids, `MergedCatalog.kt:42-43`) here.
- **`artworkAlbumId` = the first grouped album's id** (`AppModel.swift:494`), resolved
  to art lazily at render time via `catalog.albumsById[artworkAlbumId]` → `AlbumArt(...)`.
- **`searchKey` folds the artist name only** (`AppModel.swift:497`,
  `Fmt.fold`) — no album/genre folded in, so search is name-scoped (§5).

### 3.3 Filtered artist results

Add `BrowseRows.filteredArtists(query)` mirroring `filteredAlbums`/`filteredSongs`
(`BrowseModels.kt:145-159`):

```kotlin
fun BrowseRows.filteredArtists(query: String): List<ArtistRow> {
    val folded = Fmt.fold(query).replace("\n", "")   // strip \n (§4.1 browse.md)
    return artistRows.filter { folded.isEmpty() || it.searchKey.contains(folded) }
}
```

**Filters do NOT constrain the artist list.** iOS `BrowseFilter` fields apply per kind
(`BrowseModel.swift:100-149`): for the Artists kind the only applicable fields are
`artist`/`albumCount`/`songCount`, and a clause whose field doesn't apply to the row's
kind passes the row (`BrowseModel.swift:232`). Android's P1 filter cut is
`genre/bpm/key/source` (`BrowseModels.kt:56-90`, all album/song fields), so **none of
them apply to an artist row** — the artist list is derived from the FULL catalog
regardless of the sources rail / genre / bpm / key selections. Emulator note: switching
to Artists with a source chip selected shows all artists (the source clause is inert on
artist rows). This matches iOS; do not attempt to filter artists by source in this
slice (record as a possible follow-up, §11).

**Sort does NOT reorder the artist list in this slice.** `SortField.forKind`
(`BrowseSort.kt:76`) has no ARTISTS members, so the sort sheet is empty for the kind
and the list stays in catalog artist-order (which is exactly iOS's default — the
Artists kind has no default sort keys and renders in `artistBrowseItems` order,
`AppModel.swift:492`). Do **not** add `albumCount`/`songCount` sort fields in this
slice unless explicitly asked (§11 follow-up). If you touch `BrowseSort` at all, keep
`SortField.forKind(ARTISTS)` returning `[]` so the sort sheet ("Add key" list) is empty
and the toolbar sort-icon stays inert.

### 3.4 Wiring into the off-main pipeline

`BrowseContent`'s `produceState` (`BrowseScreen.kt:243-263`) rebuilds results off
`Dispatchers.Default` on `(catalog, kind, debouncedQuery, filters, sortKeys)`. Add an
`ARTISTS` arm to the `when (kind)` that computes `rows.filteredArtists(debouncedQuery)`
and stores it on the `BrowseResults` holder (`BrowseScreen.kt:78-82`) — add an
`artists: List<ArtistRow> = emptyList()` field there, bump `version` the same way so
the paging budget resets in the same frame (`BrowseScreen.kt:242,393`, the §13
stale-prefix rule). The results-count header (`BrowseScreen.kt:360`) reads
`results.artists.size` when `kind == ARTISTS`. The incremental paging block
(`BrowseScreen.kt:399-465`) gets an `ARTISTS` branch rendering a `LazyColumn` of
`ArtistListRow`s with the same `PAGE_SIZE`/`PagingTrigger` machinery (keep it — 90k-row
diffing cost, §13; artist rows are far fewer but the paging harness is free to reuse).

---

## 4. Artist row (list item)

Reproduce `ArtistRow` (`BrowseView.swift:801-824`): a representative-album thumbnail +
name + counts + a trailing chevron, tap → artist detail. Compose shape (new
`ArtistListRow` in `BrowseScreen.kt`, styled like `AlbumListRow`
`BrowseScreen.kt:558-593`):

- Leading: `AlbumArt(catalog.albumsById[row.artworkAlbumId], modifier =
  Modifier.size(46.dp))` — reuse the ordered-candidate art chain (`BrowseComponents.kt:74-105`);
  placeholder when `artworkAlbumId` is null or all candidates fail. iOS uses a 46-pt
  `SongThumbnail` (`BrowseView.swift:812`).
- Title: `row.name`, one line, ellipsized.
- Subtitle: `"$albumCount album(s) · $songCount song(s)"` with iOS's exact pluralization
  (`BrowseView.swift:816`): `"${n} album${if (n==1) "" else "s"}"` etc.
- Trailing: a right chevron (`Icons.AutoMirrored.Filled.KeyboardArrowRight` or
  `Icons.Filled.ChevronRight`), dim tint — matches `chevron.right`
  (`BrowseView.swift:820`).
- Whole row `clickable → onOpenArtist(row.name)`. No long-press add-to-collection
  (there is no "add artist" collection primitive — an artist is not a collectable item;
  iOS has none either).

Row tap passes the **display name** (`row.name`) as the nav argument — the detail screen
re-derives the discography from it (§6).

---

## 5. Search within artists

- Only the name is searchable (§3.2 `searchKey = Fmt.fold(name)`), matching iOS
  (`AppModel.swift:497`). Typing "out" matches "OutKast"; "beyonce" matches "Beyoncé"
  (diacritic-insensitive fold, `Fmt.fold`, `BrowseModels.kt` / `AppModel.swift:512-514`).
- Same debounce (~180 ms, `BrowseScreen.kt:233-238`) and off-main filter as the other
  kinds; the query is transient (never persisted, `specs/browse.md` §7,
  `BrowseSessionPersistence.kt:12`).
- The query text is **shared across kinds** (one `BrowseSession.query`,
  `BrowseModels.kt:170`) exactly as today — switching Albums↔Songs↔Artists keeps the
  typed text and re-filters. iOS shares `browse.query` the same way.

---

## 6. Artist detail screen (`ArtistDetailScreen.kt`)

New `…/screens/browse/ArtistDetailScreen.kt`, porting `ArtistDetailView.swift`. Takes
the **artist display name** and navigates onward to album detail. Signature (mirrors
`AlbumDetailScreen`, `AlbumDetailScreen.kt:61-65`, plus an `onOpenAlbum` like the other
detail screens):

```kotlin
@Composable
fun ArtistDetailScreen(
    artistName: String,
    onOpenAlbum: (albumId: String) -> Unit,
    modifier: Modifier = Modifier,
)
```

### 6.1 Discography derivation (per render, from the live catalog)

Resolve fresh from the catalog on every render (the §8 album-detail doctrine,
`AlbumDetailScreen.kt:79-81`; iOS `ArtistDetailView.swift:16-18`):

```kotlin
val albums = catalog.albums.filter { it.artist.equals(artistName, ignoreCase = true) }
val allSongIds = albums.flatMap { it.trackList }   // order: album by album, in track order
```

- **Case-INSENSITIVE match** (`ArtistDetailView.swift:17`) so a mixed-casing merged
  catalog still gathers the whole discography — the SAME predicate as the §3 grouping,
  or the detail would show a subset of what the row's counts promised.
- `catalog.albums` is pre-sorted artist › name (`MergedCatalog.kt:98-101`), so `albums`
  is already in the right order (no re-sort). `allSongIds` is the flat concatenation of
  each album's `trackList` — **not** deduped, **not** resolved (raw ids, iOS
  `ArtistDetailView.swift:20`); `playNow` drops the unresolvable ones (§6.3).

### 6.2 Layout

`Scaffold`/`LazyColumn` on the app background. iOS structure
(`ArtistDetailView.swift:22-40`):

- **Header** (`ArtistDetailView.swift:42-60`): artist name (title), then
  `"$albumCount album(s) · ${allSongIds.size} songs"` (caption) — note the header song
  count is `allSongIds.size` = `Σ trackList.size` (same number as the row's `songCount`,
  §3.2). Then a row of two full-width buttons **Play all** / **Shuffle all**
  (`ArtistDetailView.swift:47-58`), **disabled when `allSongIds.isEmpty()`**.
- **Album rows** (`ArtistDetailView.swift:26-30, 62-74`): one tappable row per album —
  `AlbumArt(album, size 50.dp)`, album name, `"${album.trackList.size} tracks" +
  (album.year?.let { " · $it" } ?: "")`, trailing chevron; a divider between rows. Tap →
  `onOpenAlbum(album.id)` (opens the normal `AlbumDetailScreen`).

Reuse existing atoms: `AlbumArt` (`BrowseComponents.kt:74`), `MetaTag`
(`BrowseComponents.kt:149`). Set a test tag `"artist-detail"` on the root and
`"artist-play-all"` / `"artist-shuffle-all"` on the buttons (iOS uses those exact
accessibility ids, `ArtistDetailView.swift:39,51,55`) for emulator UI tests.

Add a snackbar host (like `AlbumDetailScreen.kt:190`) to surface a skipped-tracks /
nothing-playable message from the play funnel (§6.3).

### 6.3 ▶ Play all / 🔀 Shuffle all — the whole-discography funnel

iOS routes the discography through the reserved Now Playing setlist attributed to
History as `.artist` (`ArtistDetailView.swift:78-85`). Android has the identical path
already built for source-playlist Shuffle (`SourcePlaylistDetailScreen.kt:143-151`) —
copy it:

```kotlin
val set = graph.collections.playNow(
    songIds  = allSongIds,          // raw, non-deduped, in album/track order
    name     = artistName,
    shuffle  = shuffle,             // false = Play all, true = Shuffle all
    sourceToken = PlayContext.SOURCE_ARTIST,   // "artist" (PlayEvents.kt:29)
    originId = artistName,          // iOS uses the artist key as originId (ArtistDetailView.swift:79)
)
if (set != null) onOpenSetlist(NOW_PLAYING_SETLIST_ID, /* autoplay = */ true)
```

- `playNow` (`CollectionsStore.kt:1141-1187`) snapshots ids → `SetlistTrack`s, **drops
  unresolvable ids**, `shuffle` reorders unseeded, UPSERTS the reserved `set_now_playing`
  setlist, bumps the restart token, returns null only if the catalog isn't wired (then
  do nothing).
- Navigating to the setlist route with `autoplay = true`
  (`setlistRoute(NOW_PLAYING_SETLIST_ID, true)`, `MainActivity.kt:91-92`) makes
  `SetlistDetailScreen.start()` (`SetlistDetailScreen.kt:113-140`) call
  `playbackController.playSetlist(sl, store.historyContext(NOW_PLAYING_SETLIST_ID))`.
- `historyContext(NOW_PLAYING_SETLIST_ID)` (`CollectionsStore.kt:1239-1244`) reads the
  `nowPlayingSource` just recorded ("artist") and returns
  `PlayContext(source = "artist", contextId = set_now_playing, contextName = artistName)`
  — exactly the `realize-play.md` §7 / `browse.md` History table row for artist. **No
  new PlayContext wiring is needed** — the token, the companion, and the funnel all
  pre-exist.
- **Skip-unplayable / nothing-playable:** `playSetlist` returns a `QueueOutcome`
  (`SetlistDetailScreen.kt:127-139`, `PlaybackController.kt:238-243`). The artist screen
  need not render its own transport (the setlist screen owns it after navigation), but if
  you want Play-all feedback on the artist screen itself, surface the same
  `"Playing m of n — k not playable on Android"` string (`SetlistDetailScreen.kt:130-135`)
  on the artist snackbar. Simplest faithful path: just navigate (iOS pushes and lets the
  Now Playing screen report); the setlist screen already shows the skip summary. Do NOT
  build a second queue path — Play-all is `playNow` + navigate, nothing more.

Reserved-doc lifecycle (purged at store launch, hidden from listings) is handled by the
store (`realize-play.md` §5, `CollectionsStore.kt`) — no artist-specific work.

---

## 7. Navigation wiring

Add one route + one helper alongside the existing ones (`MainActivity.kt:78-95`):

```kotlin
const val ARTIST_ROUTE = "artist/{artistName}"
fun artistRoute(artistName: String): String = "artist/${android.net.Uri.encode(artistName)}"
```

`Uri.encode` is essential — an artist name can contain `/`, `?`, spaces, `#`
(`albumRoute` already encodes, `MainActivity.kt:85`). Register the composable (mirror
the album route, `MainActivity.kt:284-290`):

```kotlin
composable(ARTIST_ROUTE, arguments = listOf(navArgument("artistName") { type = NavType.StringType })) { entry ->
    ArtistDetailScreen(
        artistName = entry.arguments?.getString("artistName").orEmpty(),
        onOpenAlbum = { albumId -> navController.navigate(albumRoute(albumId)) },
    )
}
```

`BrowseScreen` currently takes only `onOpenAlbum` (`BrowseScreen.kt:92-95`). Add an
`onOpenArtist: (artistName: String) -> Unit` parameter, thread it through `BrowseContent`
to the `ArtistListRow`, and wire it in `MainActivity.kt:190-192`:
`BrowseScreen(onOpenAlbum = …, onOpenArtist = { name -> navController.navigate(artistRoute(name)) })`.

The nav-title bar (`MainActivity.kt:118-121`) derives the detail title from the route;
the artist name is the natural title — either add an `ARTIST_ROUTE` arm to the `when` or
let `ArtistDetailScreen` render the name in its own header (§6.2) and leave the bar
title blank/generic for that route (iOS uses `.navigationTitle(artistName)`,
`ArtistDetailView.swift:35`). Prefer showing the name in the top bar for parity; keep it
a small `when(currentRoute)` addition.

---

## 8. Empty / edge states

- **No albums for a name** (stale nav after a catalog refresh dropped the artist):
  `albums.isEmpty()` → render an "Artist not found" centered message (like
  `AlbumDetailScreen.kt:89-95`); Play/Shuffle already disabled by
  `allSongIds.isEmpty()`.
- **Catalog still loading** on the detail screen: `catalog == null` → spinner
  (`AlbumDetailScreen.kt:85-87`).
- **Artists kind, empty catalog:** the existing `EmptyState` message
  (`BrowseScreen.kt:394-397`, "Nothing here yet — pull the catalog from Settings")
  covers it; the "No matches" branch covers a query miss.
- **Single-artist catalog / all-same-artist:** one artist row; grouping still terminates
  (`i = j` advances). Verified by the §3 single-pass invariant.

---

## 9. History attribution (already correct once §6.3 is wired)

A play started from Play-all/Shuffle-all is a queue run tagged
`(source = "artist", contextId = "set_now_playing", contextName = artistName)` — the
persisted history value (`realize-play.md` §7 table; `PlayEvents.kt:29`;
`history.md` §2 token list, which already lists `artist`). Each track start emits a
`PlayStarted` carrying that captured context (`PlaybackController.kt:227-233`,
`PlayEvents.kt:63-71`); the 30 s same-song dedup window (`history.md` §4) is unaffected.
**Do not rename the `artist` token** — it is the on-disk history value and a future S3
sync merges it.

---

## 10. Emulator-verifiable acceptance (all on the `pocketdj` AVD, live prod catalog)

Everything in this slice is **emulator-verifiable** — ExoPlayer, MediaSession, and the
public-rips stream all run in the emulator; nothing here is device-only.

Unit tests (JVM, extend `…/screens/browse/BrowseEngineTest.kt` — its fixture builds a
`MergedCatalog.merge(listOf(IndexJson(...)))` from in-memory albums/songs,
`BrowseEngineTest.kt:1-12`):

1. **Grouping**: albums by ["OutKast","Outkast","Jay-Z"] → **2** artist rows; the
   "OutKast" row has `albumCount = 2`, `name = "OutKast"` (first casing), `songCount =`
   Σ of both `trackList.size`, `artworkAlbumId =` first album id. (bit iOS
   `AppModel.swift:483-499`.)
2. **songCount counts trackList, not resolved tracks**: include a `trackList` entry with
   a missing song id and a duplicate id → `songCount` still counts them (§3.2).
3. **Search**: `filteredArtists("beyonce")` matches a "Beyoncé" row (diacritic fold);
   `filteredArtists("")` returns all; a `\n` in the query can't match across rows.
4. **Persistence round-trip**: `BrowseSessionState(kind = ARTISTS,…).toSnapshot()` →
   `"artists"`; `BrowseSnapshot(kind = "artists").toSessionState().kind == ARTISTS`; an
   unknown `kind = "zzz"` → ALBUMS (`BrowseSessionPersistenceTest.kt` style). Confirms
   the iron law.
5. **playNow attribution** (store-level, no Compose): `playNow(ids, name, shuffle=false,
   sourceToken = SOURCE_ARTIST, originId = name)` then
   `historyContext(NOW_PLAYING_SETLIST_ID)` returns source `"artist"`, contextId
   `set_now_playing`, contextName = name; unresolvable ids dropped from `tracks`.

Instrumented/UI (emulator): switch the Browse toggle to **Artists** → list renders with
counts; type in the search field → list filters by name; tap an artist → `artist-detail`
appears with album rows and the two buttons; tap **Play all** → navigates to the Now
Playing setlist and playable tracks stream (verify via the mini-player / notification);
tap an album row → normal album detail. Baseline unit-test count before this work is
**234** (ground rules) — the new tests must move that number (the
`XcodeGen`-style trap doesn't apply to Gradle, but still assert the count grew, not just
a green run).

---

## 11. Explicitly cut from this slice (record, don't build)

- **Sort on the Artists kind** (by name / albumCount / songCount). iOS registers
  `artist`/`albumCount`/`songCount` as sortable for the artist kind
  (`BrowseModel.swift:100-149`); Android's `SortField` has no ARTISTS members
  (`BrowseSort.kt:12-31`) and this slice keeps `forKind(ARTISTS) == []` (empty sort
  sheet). Follow-up: add `ARTIST`(already exists but no ARTISTS kind)/`ALBUM_COUNT`/
  `SONG_COUNT` sort fields + `ArtistRow` value extractors.
- **Filtering the artist list by source/genre/bpm/key.** Inert by design (§3.3) — the
  P1 filter cut's fields are all album/song fields. A future "artists in source X" would
  need artist-kind filter fields (iOS's `artist`/`albumCount`/`songCount` clauses,
  `BrowseModel.swift`).
- **Online (aoss) search for artists.** iOS keeps the Artists kind **always on-device**
  (`BrowseView.swift:196` / `browse.md` §4.2 mode toggle) — Android matches by simply
  not offering the online path here (the online pipeline is unbuilt on Android anyway,
  `BrowseModels.kt:25-30`).
- **Add-to-collection from an artist row/screen.** No "add artist" primitive exists on
  iOS; an artist is derived, not a collectable item.
- **Artist-scoped grid/art collage, top tracks, external links** — none exist on iOS;
  the detail is albums-list + Play/Shuffle only.

---

## 12. Risks / traps

1. **Duplicate LazyColumn keys from case-mismatched grouping.** If you group
   case-*sensitively* (or key the row by `id` derived case-sensitively) while the catalog
   sort is case-*insensitive*, two adjacent "OutKast"/"Outkast" albums split into two
   rows with the same folded key → Compose throws on duplicate keys. Use the SAME
   case-insensitive predicate for grouping (§3.2) as `MergedCatalog` uses for sorting
   (`MergedCatalog.kt:98-101`). This is the single highest-severity trap.
2. **songCount drift between the row and the detail.** The row's `songCount`
   (Σ `trackList.size`, §3.2) and the detail header's count (`allSongIds.size`, §6.2)
   must be the same number — both are the flat `trackList` total, NOT resolved tracks. If
   one uses `MergedCatalog.tracks(...)` (drops missing/dupes) and the other uses raw
   `trackList`, the counts disagree and the discrepancy is user-visible.
3. **Unencoded artist name in the nav route.** Names contain `/`, `&`, spaces, `#`; a
   raw route string breaks navigation or truncates the name. Always `Uri.encode`
   (§7) — `albumRoute` already does (`MainActivity.kt:85`).
4. **Play-all with an all-AM-only discography.** On Android many tracks are
   metadata-only (no public rip, no MusicKit — `docs/ARCHITECTURE-ANDROID.md:47-49`).
   `playNow` keeps them in the reserved setlist, but `playSetlist` skips the unplayable
   ones at queue build (`realize-play.md` §6.3, `PlaybackController.kt:219-222`); an
   all-unplayable artist yields `QueueOutcome.NothingPlayable` → the setlist screen shows
   "None of these tracks are playable on this device yet" (`SetlistDetailScreen.kt:137`).
   Do not treat that as an error to suppress — it's the honest state.
5. **Stale artist after a catalog refresh.** The detail re-derives from the live catalog
   every render (§6.1); if a refresh drops every album by that name, render "Artist not
   found" (§8) rather than a blank screen with dead buttons.
6. **Paging-budget reset on kind switch.** The `ARTISTS` branch must bump
   `BrowseResults.version` like the other kinds (`BrowseScreen.kt:253-260`) so switching
   Songs→Artists doesn't render the previous set's large prefix for a frame
   (`browse.md` §13). Reuse the existing `version = ++resultVersion` pattern verbatim.
</content>
</invoke>
