# For You ▸ New: albums vs singles

**Status:** designed (feat/foryou-new-kind-filter), not implemented
**Owner ask (Levi, 2026-11-23, verbatim):**
> "for new we should be able to hide or sort albums vs singles, for me i would only want to see
> albums for others singles and others albums first and then singles as three separate user stories"

## 0. User stories

| | Story | Mode (`NewReleaseKindFilter`) |
|---|---|---|
| US1 | As a listener who only cares about albums (Levi), I can hide singles on New. | `albums`: "Albums only" |
| US2 | As a listener who follows singles, I can see only singles. | `singles`: "Singles only" |
| US3 | As a listener who wants both, I see albums first, then singles. | `albumsFirst`: "Albums, then singles" |
| — | Today's behaviour: everything mixed, newest first. **The default for every install, new or upgraded.** | `all`: "Everything" |

Raw values `all | albums | singles | albumsFirst` are persisted. Never rename them.

Why `all` stays the default: the request says three stories for three *different* listeners, so
no single one of them is right to impose. Today's mix is also the only mode that cannot hide a
record from someone who doesn't know the setting exists. Levi picks "Albums only" once per device.

## 1. What exists today (both platforms)

| Piece | iOS | Android |
|---|---|---|
| Screen | `apple/PocketDJ/Views/ForYouDetailViews.swift` `NewReleasesView` | `android/.../screens/foryou/NewReleasesScreen.kt` (pure helpers in `NewReleasesPresentation`) |
| Pipeline | `outNow()`/`comingSoon()` → `offered()` (drop 👍'd, keep pre-added) → `sunkLast()` (👎 to the bottom) → render; `live()` (drop 👎) → ▶/🔀 | same |
| Sections | Liked — not added · Out now · Coming soon | same |
| Kind | `ArtistReleaseEntry.releaseKind`, mapped in `ArtistsCatalogResponse.entries`: `isSingle` → "single", `isCompilation` → "compilation", else **"album"**. The mapping **never produces "ep"**, so today every EP is badged "Album" (only the UI fixture says "ep"). `trackCount` comes from the same response. | `ReleaseFeedModels.kt` `entry()`: the identical mapping |
| Liked metadata | `LikedRelease.kind/trackCount/title` | same |
| New tile count | `ForYouGrid.tiles` → `ForYouTiles.build(newReleaseCount:comingSoonCount:newEmptyNote:)` | `ForYouGrid.tiles` reads `ForYouReleaseSource.feed()`, adapted by `ReleaseFeedForYouSource` (in `ReleaseFeedService.kt`), which is constructed in `ForYouTilesScreen.kt:326` |
| Tile ▶/🔀 | `ForYouView.tileMenu` for `.new`: outNow minus 👎 and 👍 | the New tile has no ▶ (`ForYouTilesScreen.kt:457` returns no ids) |
| Car | `CarPlayForYou.newReleaseItems` (rows + ▶/🔀 + the tile via `ForYouGrid.tiles`) | Android Auto does not list New (`auto/` has no For You) |
| Prefs | `SettingsStore` → `SettingsData` (UserDefaults `pdj.settings.v1`). **UI prefs are device-local by doctrine** (`SettingsCredentialsSync.swift`: only the credential subset syncs) | `AppSettingsStore` + `LegacyPrefKeys` (DataStore), e.g. `collectionSort` |

So **four** iOS call sites derive "the New list": the screen, the grid, the tile menu and CarPlay.
They all have to apply the filter the same way, which is why section 3 puts it in one pure function.

## 2. Classification rule

`AppModel.swift:98` already warns that `releaseKind` is not fully trustworthy. Apple's own
release-type rule (1–3 tracks = single; 4–6 tracks under 30 min = EP; more = album) is mostly
visible in the **title**, because Apple suffixes catalog names with `" - Single"` / `" - EP"`.
The rule, first match wins:

```
classify(kind: String?, name: String?, trackCount: Int?) -> ReleaseKindClass   // .album | .ep | .single
 1. name ends with " - Single" (case-insensitive, trimmed; also "– Single" en dash) → .single
 2. name ends with " - EP"                                                         → .ep
 3. kind == "single"                                                               → .single
 4. kind == "ep"                                                                   → .ep
 5. trackCount in 1...3                                                            → .single   // the "album" that is really a single
 6. trackCount in 4...6                                                            → .ep
 7. otherwise (≥7 tracks, "album", "compilation", or nothing known)                → .album
```

- An Apple-declared single with many tracks (a remix bundle: "Song - Single", 8 tracks) **stays a
  single**. The name and the flag win over the count, because those come from Apple's own type and
  the count only guesses at it.
- Unknown everything → `.album`. An unclassifiable row is a whole record more often than not, and
  "Albums only" is the mode most likely to be in use (Levi's).
- `.compilation` is folded into `.album` for filtering, but the badge keeps saying "Compilation".

### Where EPs go

**Filtering is two buckets: `album` = {album, EP, compilation}; `single` = {single}.** An EP is a
body of work, not a one-song drop. Someone who says "only albums" is avoiding the trickle of
one-track singles, not a 5-track record. That also makes the fuzzy 4–6 boundary harmless: rules
5–6 only change the *badge*, never what a filter hides. The one boundary that hides things is
3 vs 4 tracks (a 3-track 40-minute ambient record reads as a single). Without durations that is
accepted, and noted in §9.

| Story | Albums | EPs | Singles |
|---|---|---|---|
| US1 Albums only | shown | **shown** | hidden |
| US2 Singles only | hidden | **hidden** | shown |
| US3 Albums, then singles | first group | **first group** (with albums, by date) | second group |

The menu label says "Albums only", and the menu footnote says "EPs count as albums" (one line,
`Text` in the menu section footer on iOS, a disabled caption item on Android).

### The badge follows the class

The row badge today shows the raw `releaseKind.capitalized`. It changes to the **classified**
label (`Album` / `EP` / `Single` / `Compilation`). Otherwise a 2-track "Album" would sit under
"Singles only" with an "Album" badge, and the filter would look broken. The badge gets the id
`new-release-kind-<artistId>` with `accessibilityValue` = class raw.

## 3. The one pure function

New file iOS `apple/PocketDJ/Services/Recommendations/NewReleaseKind.swift`; Android
`android/.../screens/foryou/NewReleaseKind.kt`. Same cases, same names:

```swift
enum ReleaseKindClass: String { case album, ep, single
    var isAlbumBucket: Bool { self != .single } }

enum NewReleaseKindFilter: String, CaseIterable, Identifiable, Codable {
    case all, albums, singles, albumsFirst
    var label: String        // "Everything" · "Albums only" · "Singles only" · "Albums, then singles"
    var systemImage: String  // "square.stack" · "opticaldisc" · "music.note" · "list.number"
}

enum NewReleaseKinds {
    static func classify(kind: String?, name: String?, trackCount: Int?) -> ReleaseKindClass
    static func badge(kind: String?, cls: ReleaseKindClass) -> String   // keeps "Compilation"

    struct Arranged<T> {
        var albums: [T]          // album bucket, in input order (empty in .singles)
        var singles: [T]         // single bucket, in input order (empty in .albums)
        var grouped: Bool        // true only for .albumsFirst (render the two group headers)
        var flat: [T]            // .all → input order untouched; else albums + singles
        var hiddenAlbums: Int    // incl. EPs
        var hiddenEPs: Int       // subset of hiddenAlbums, for the copy
        var hiddenSingles: Int
    }
    /// Filter + order ONE section. `sink` = the existing sunkLast rule, applied INSIDE each group
    /// so a 👎'd album sinks below the live albums but stays above the singles.
    static func arrange<T>(_ items: [T], mode: NewReleaseKindFilter,
                           cls: (T) -> ReleaseKindClass, sink: ([T]) -> [T]) -> Arranged<T>

    /// "3 singles hidden" · "1 single hidden" · "2 albums hidden" · "2 albums & EPs hidden"
    /// (any EP among them) · nil when nothing is hidden.
    static func hiddenNote(albums: Int, eps: Int, singles: Int) -> String?
}
extension ArtistReleaseEntry { var kindClass: ReleaseKindClass }   // classify(releaseKind, releaseName, trackCount)
extension LikedRelease      { var kindClass: ReleaseKindClass }   // classify(kind, title, trackCount)
```

`.all` must return `flat == sink(items)` exactly, so today's behaviour is byte-for-byte what the
default produces. A unit test asserts this.

## 4. Behaviour per surface

### 4.1 New screen sections

Pipeline, per section: `offered()` → **`arrange(mode, sink: sunkLast)`** → render. The filter
comes after `offered` (a 👍'd release still leaves Out now and moves to Liked) and wraps `sunkLast`.

| Section | `all` | `albums` | `singles` | `albumsFirst` |
|---|---|---|---|---|
| Liked — not added | as today | album-bucket rows only | singles only | albums, then singles (no sub-headers; the section is short and already ordered by state/like time inside each group) |
| Out now | newest first | albums+EPs, newest first | singles, newest first | sub-header **Albums** (`new-release-group-albums-outNow`), newest first; then sub-header **Singles** (`new-release-group-singles-outNow`), newest first |
| Coming soon | soonest first | albums+EPs | singles | same two groups, soonest first inside each (`…-comingSoon`) |

- A section that ends up empty is not drawn (as today). In `albumsFirst`, a group sub-header is
  drawn only when **both** groups are non-empty. A lone "Albums" header over the whole section is
  noise.
- The existing section header ids (`new-release-section-outNow`, `…-comingSoon`) are unchanged in
  every mode, so existing tests keep passing.
- "Add all (n)" in Liked counts and adds **only the visible rows**. The hidden ones aren't on
  screen, and an Add-all that adds something the user can't see is a surprise.
- "Pre-added ✓" rows in Coming soon follow the filter like any other row.

### 4.2 ▶ / 🔀 (screen, tile menu, CarPlay): what plays is what's shown

`liveOutNow = live(arranged(outNow).flat)`:
- `albums` / `singles`: only that bucket plays.
- `albumsFirst`: ▶ queues album tracks first, then single tracks.
  `ReleaseStreaming.tracks(forReleaseIds:)` already preserves input order (`byIndex`), so no
  change is needed there. 🔀 shuffles the whole queue, because shuffle means shuffle.
- The `ReleaseStreaming.maxReleases = 25` cap now applies after the ordering. In `albumsFirst`
  with more than 25 live releases, singles are the ones cut. That follows directly from "albums
  first". Document it in a comment and don't fight it.
- The transport still gates on `liveOutNow` (the rule in the existing comment), which is now the
  filtered list. So "Singles only" with no singles out now means ▶ is disabled, not lit and dead.

### 4.3 The New tile (For You grid, all platforms that draw it)

- **The count is the filtered count.** Opening the tile must show the number it promised.
  iOS: `ForYouGrid.tiles(...)` gains `newKind: NewReleaseKindFilter = .all`. It filters
  `releases` with `ReleaseFeedItem.entry.kindClass` before both `newCount` and `comingSoonCount`.
  `albumsFirst` and `all` give the same count.
- Subtitle (iOS `ForYouTiles.newReleaseSubtitle` gains `kind:`): `albums` →
  "Albums from artists you play · last 30 days" (and the matching variants for the other three
  shapes); `singles` → "Singles from …"; `all`/`albumsFirst` → unchanged copy.
- **Zero because of the filter** is its own empty note, because "No releases in the last 30 days"
  would be a false claim: `newEmptyNote = hiddenNote(...)` → e.g. "No new albums · 3 singles hidden".
  The order is: the filter note when the unfiltered count is > 0, otherwise the existing
  `emptyReason().tileNote`.
- Callers: `ForYouView` (passes `settings.newReleaseKindFilter`) and `CarPlayForYou.forYouTileModels`
  (passes `services.settings.newReleaseKindFilter`; `IntentServices.settings` already exists).
- Android: **no `ForYouGrid.kt` / `ForYouTiles.kt` edit** (both are shared with
  `feat/android-parity2`). The filter goes in the adapter. A new
  `KindFilteredForYouSource(service, mode)` in `screens/foryou/NewReleaseKind.kt` implements
  `ForYouReleaseSource`: `feed()` returns only shown releases, and `emptyTileNote()` returns the
  hidden note when the filter emptied it. `ForYouTilesScreen.kt:326` constructs it in place of
  `ReleaseFeedForYouSource` (a one-line change, keyed on the mode). The Android subtitle prefix
  ("Albums from …") waits for the parity branch to land (§9).

### 4.4 Tile ▶/🔀 menu (iOS `ForYouView.tileMenu`)

`live` = the same pipeline as 4.2 (`offered` → `arrange` → drop 👎). It replaces the inline
filter. Android has no New tile ▶.

### 4.5 CarPlay

`CarPlayForYou.newReleaseItems(nowMs:)` → `arrange(outNow minus 👎/👍, mode).flat`. The rows,
row-tap "play from here" and ▶/🔀 all read it, so the car plays exactly what the phone's screen
plays. The empty line (`CarPlayScene.pushForYou` `emptyText`) becomes the hidden note when the
filter emptied it ("No new albums · 3 singles hidden"). There's no "Show all" in the car: changing
a preference while driving isn't a CarPlay job, and the note says why the list is empty. Android
Auto does not list New, so nothing to do there.

### 4.6 Empty and partial states on the screen

- **Partial** (the filter hides some rows, others show): a footer row at the bottom of the list,
  `new-kind-hidden-footer`, reading "3 singles hidden · **Show all**". `accessibilityValue` is the
  hidden count. "Show all" (`new-kind-show-all`) sets the mode to `all` (persisted). It's the same
  setter as the menu, and the menu sets it back. The counts cover every section, Liked included,
  and count rows that **would render** under `all` (👎'd rows render, so they count).
- **Everything hidden** (the filter emptied it, the unfiltered render has rows): a filter-aware
  empty state, `new-kind-empty`, instead of `new-releases-empty`.
  Title: "No new albums" / "No new singles". Detail: the hidden note + " Your New filter is set
  to <label>." Button: **Show all** (`new-kind-show-all`).
- **Nothing at all** (the unfiltered render is empty too): the existing reason-based
  `emptyState`, unchanged. The filter isn't the cause, so it isn't mentioned.

### 4.7 👍 auto-add, sweep, hydration: unaffected

The filter is **view-only**. `NewReleaseLikeAdder.liked/sweep/maintain/hydrateMissing`, the
feedback store, `LikedReleasesStore` and the feed fetch/seed don't read it. A queued pre-order
single still auto-adds on release day under "Albums only". You can only 👍 a visible row, and
nothing already in flight is cancelled when a filter hides its row. If a hidden liked row fails,
it shows when he switches back to Everything, and the footer count includes it.

## 5. The control

**Where:** New's ⋯ menu (`collectionToolbar(... menuItems: overflowMenu)` on iOS; the
`DropdownMenu` behind `foryou-new-more` on Android), above "Check for new releases". A sort/filter
choice made on the screen it affects, next to the only other screen-level action. It's not in
Settings, because nobody looks there for a list filter. The partial footer (4.6) shows the filter
is active, so it can't hide things silently.

- iOS: `Picker("Show", selection: $settings.newReleaseKindFilter)` with
  `.pickerStyle(.inline)` inside a `Section("Show")` in the menu, giving four checkmarked rows.
  The section footer is "EPs count as albums". Writes go through `settings.persist()` (the
  `collectionSort` pattern in `PlaylistsView.sortMenu`).
  Ids: section `foryou-new-kind-menu`; items `foryou-new-kind-all`, `foryou-new-kind-albums`,
  `foryou-new-kind-singles`, `foryou-new-kind-albumsFirst` (`accessibilityIdentifier` on each
  `Text` tag, plus `accessibilityValue("selected")` on the current one for tests).
- Android: four `DropdownMenuItem`s under a disabled "Show" caption, with a ✓ `trailingIcon` on
  the current one and the same `testTag`s. A divider, then "Check for new releases".

**Persistence: per install, like `collectionSort`, not iCloud-synced.**
- iOS: `SettingsStore.newReleaseKindFilter: NewReleaseKindFilter` ↔ `SettingsData.newReleaseKindFilter: String?`
  (missing or unknown → `.all`, upgrade-safe). Wire it into `init`, `persist()`, `resetToDefaults`
  and `SettingsData.default` like `collectionSort`. It does **not** join
  `SettingsCredentialsDocument`: that doc's doctrine is "credentials only, UI prefs never ride
  along". Levi sets it once per device. If he wants it to follow his Apple ID, that's a small
  synced-prefs doc (§9), not a change to the credential doc.
- Android: `AppSettings.newReleaseKind: String = "all"`, `LegacyPrefKeys.NEW_RELEASE_KIND =
  PrefKey.string("newReleaseKind", "all")`, `Keys.NEW_RELEASE_KIND`, and
  `suspend fun setNewReleaseKind(raw)`. That's three small additive lines in `AppSettingsStore.kt` /
  `PrefKey.kt`, which is the "small settings addition" budget. The screen and the tiles screen
  read `graph.settings.settings.map { NewReleaseKindFilter.from(it.newReleaseKind) }`.

**UI-test seam (iOS):** under `ReleaseFeedService.wantsUIFixture` (PDJ_REC_FIXTURE=1 + PDJ_USE_FIXTURE),
`PocketDJApp` sets `settings.newReleaseKindFilter` at launch from env `PDJ_NEW_KIND`
(missing → `.all`). That way a test that leaves "Albums only" behind can't leak into the next
test through the app's persisted UserDefaults. A second env, `PDJ_NEW_FIXTURE_KINDS=1`, appends
two extra fixture rows (§7). It's off by default so the existing fixture counts in
`CarPlayForYouTests` / `CollectionToolbarUITests` / `ReleaseStreamingTests` don't move.

## 6. Acceptance criteria

### US1: Albums only (Levi)
1. ⋯ → Show → Albums only: Out now and Coming soon show albums, EPs and compilations. Singles,
   including an "album" with ≤3 tracks and anything titled "… - Single", are not drawn.
2. Liked — not added shows only album-bucket rows. Add all (n) counts and adds only those.
3. ▶/🔀 on the screen, the tile's long-press ▶/🔀, and CarPlay's New ▶/🔀 queue only album-bucket
   releases. ▶ is disabled when no album is out now.
4. The New tile badge counts only album-bucket releases. The subtitle reads "Albums from artists
   you play · …".
5. A footer says "n singles hidden · Show all". Show all restores everything and the menu shows
   Everything checked.
6. The choice survives relaunch (persisted) and defaults to Everything on a fresh install and on
   upgrade.
7. A 👍 on a visible album still adds it. Hidden liked singles keep their queued/awaiting-release
   retries.

### US2: Singles only
1. Only single-bucket rows render in every section. Albums, EPs and compilations are hidden.
2. ▶/🔀, the tile count and CarPlay match (singles only). The subtitle reads "Singles from …".
3. Footer: "n albums hidden" (or "n albums & EPs hidden" when any EP is among them).
4. When no singles are left (e.g. the only one was 👍'd and added): the `new-kind-empty` state
   reads "No new singles", says what's hidden, and offers Show all. The tile's zero says
   "No new singles · n albums hidden", never "No releases in the last 30 days".

### US3: Albums, then singles
1. Out now: every album-bucket row (newest first) comes before every single (newest first), under
   "Albums" / "Singles" sub-headers when both exist. Coming soon is the same, soonest first in
   each group.
2. A 👎'd album sinks to the bottom of the **albums** group (above the singles). A 👎'd single
   sinks to the bottom of the list.
3. ▶ plays album tracks before single tracks. 🔀 shuffles all of them.
4. Nothing is hidden: no footer, and the tile count equals Everything's.

### Everything (default, regression)
Output identical to today: same rows, same order, same ids, and the existing UI tests unchanged.

## 7. Tests

### 7.1 Unit (same cases on both platforms)

`NewReleaseKindTests` (iOS `apple/Tests/Unit/NewReleaseKindTests.swift`; Android
`app/src/test/.../screens/foryou/NewReleaseKindTest.kt`):
- `classify` table: "X - Single" + kind album + 9 tracks → single. "X - EP" → ep. "X – Single"
  (en dash) → single. kind single + 8 tracks → single. kind album + 2 tracks → single. kind album +
  5 → ep. kind album + 12 → album. compilation → album (badge "Compilation"). Everything nil →
  album. kind "ep" (the fixture) → ep.
- `arrange` for each mode over a mixed list with 👎'd rows: `.all` == `sunkLast(input)` exactly.
  `.albums` keeps EPs. `.singles` drops EPs. `.albumsFirst`: albums group then singles, sink applied
  inside each group, `grouped == true`, and the hidden counts are right in every mode.
- `hiddenNote`: 0/1/n singular and plural, "albums & EPs" when eps > 0, nil when nothing is hidden.
- `liveOutNow` order under `.albumsFirst` (album ids before single ids) feeds the streaming order.

iOS also:
- `ForYouGridTests` (or the existing grid tests): the New count with `.albums` / `.singles`, and the
  filter empty note winning over `emptyReason` when the unfiltered count > 0. Also
  `ForYouTiles.newReleaseSubtitle(kind:)` copy.
- `CarPlayForYouTests`: with `settings.newReleaseKindFilter = .albums` over `uiFixtureEntries`,
  `forYouRows("new")` has only `rel:9000000001`. With `.singles`, only `rel:9000000002`. With
  `.albumsFirst` + the kinds fixture, the album row precedes the single rows.
- `SettingsStore` round trip of `newReleaseKindFilter`; a missing key or unknown raw → `.all`.
- `NewReleasesView.likedSelection` stays as-is. A test on the filtered Liked rows uses `arrange`
  with `LikedRelease.kindClass`.

Android also: `KindFilteredForYouSource` feed/emptyTileNote. `NewReleasesPresentationTest` gets the
footer and empty copy. `AppSettingsStore` default "all".

### 7.2 UI tests: ids

| id | element |
|---|---|
| `foryou-new-more` (Android) / the toolbar ⋯ from `collectionToolbar(idPrefix: "foryou-new")` (iOS) | opens the menu |
| `foryou-new-kind-menu` | the "Show" section |
| `foryou-new-kind-all` · `-albums` · `-singles` · `-albumsFirst` | the four choices (`accessibilityValue` "selected" on the current one) |
| `new-release-kind-<artistId>` | a row's kind badge (value = class raw) |
| `new-release-group-albums-<outNow\|comingSoon>` · `new-release-group-singles-<…>` | `albumsFirst` sub-headers |
| `new-kind-hidden-footer` | "n … hidden · Show all" (value = hidden count) |
| `new-kind-show-all` | Show all (footer and filter-empty state) |
| `new-kind-empty` | the filter-emptied state |
| existing: `new-release-<artistId>`, `new-release-section-<status>`, `new-liked-row-<storeId>`, `rec-accept-rel:<id>`, `foryou-tile-new`, `foryou-new-play` | unchanged |

Fixture (default): 900001 "Second Side" album 9 tracks (out now, 2 d), 900002 "Late Cut" single
2 tracks (out now, 9 d), 900003 "Preorder EP" ep 5 tracks (coming soon), liked 9000000004
"Liked Record" album.
`PDJ_NEW_FIXTURE_KINDS=1` adds 900005 "Fresh Cut - Single" kind single 1 track (out now, **1 d**, so
it's newer than the album) and 900006 "Midnight Edit" kind **album** 1 track (out now, 3 d: the
mislabelled single).

### 7.3 UI tests: one per story (iOS `apple/Tests/UI/ForYouNewKindUITests.swift`; same tags as Compose tests on Android if the parity branch owns androidTest infra, otherwise optional this pass)

1. **US1 `testAlbumsOnlyHidesSinglesAndCanShowAllAgain`** (`PDJ_NEW_FIXTURE_KINDS=1`, `PDJ_NEW_KIND`
   unset): open New. Under Everything, 900005 sits above 900001 (date order). Pick ⋯ →
   `foryou-new-kind-albums`. 900001 and 900003 (EP) exist. 900002, 900005 and 900006 (the
   mislabelled "album") do **not**. `new-kind-hidden-footer` value is "3". `foryou-new-play` is
   enabled. Go back: `foryou-tile-new`'s label contains "Albums". Re-open, tap `new-kind-show-all`:
   900002 is back and the footer is gone.
2. **US2 `testSinglesOnlyShowsSinglesAndExplainsWhenNoneAreLeft`** (`PDJ_NEW_KIND=singles`): 900002
   exists. 900001, 900003 and `new-liked-row-9000000004` don't. `new-release-section-comingSoon`
   doesn't exist. Footer value "3" (album + EP + liked album). Tap `rec-accept-rel:9000000002`: the
   fixture port adds it, and `new-kind-empty` appears saying "No new singles". `new-kind-show-all`
   brings back 900001.
3. **US3 `testAlbumsFirstPutsEveryAlbumAboveEverySingle`** (`PDJ_NEW_FIXTURE_KINDS=1`,
   `PDJ_NEW_KIND=albumsFirst`): `new-release-group-albums-outNow` and
   `new-release-group-singles-outNow` exist. `frame.minY` of 900001 < the singles header <
   900005 < 900006 < 900002 (singles newest first). No `new-kind-hidden-footer`.

## 8. Code changes

### iOS
| File | Change |
|---|---|
| `PocketDJ/Services/Recommendations/NewReleaseKind.swift` **(new)** | §3: `ReleaseKindClass`, `NewReleaseKindFilter`, `NewReleaseKinds.{classify,badge,arrange,hiddenNote}`, `ArtistReleaseEntry.kindClass`, `LikedRelease.kindClass`. A helper `NewReleaseKinds.liveOutNow(outNow:feedback:scope:mode:nowMs:) -> [ReleaseFeedItem]` (offered → arrange → drop 👎) that `ForYouView.tileMenu` and `CarPlayForYou.newReleaseItems` both call, so there's one derivation instead of two inline filters. |
| `PocketDJ/Settings/SettingsStore.swift` | `newReleaseKindFilter` + `SettingsData.newReleaseKindFilter: String?` (init/persist/reset/default) |
| `PocketDJ/Views/ForYouDetailViews.swift` | `@Environment(SettingsStore.self)`. In the body, run `arrange` per section and on Liked, compute the hidden totals, and use the three-way empty logic (4.6). `section(...)` takes an `Arranged` and draws group sub-headers. The badge comes from `NewReleaseKinds.badge`. `overflowMenu` gets the Show picker. Footer row. `liveOutNow` from the arranged flat. Update the header doc comment. |
| `PocketDJ/Services/Recommendations/ForYouGrid.swift` | `tiles(..., newKind:)`: filtered counts + filter empty note |
| `PocketDJ/Services/Recommendations/ForYouTiles.swift` | `build(..., newKind:)` → `newReleaseSubtitle(..., kind:)` |
| `PocketDJ/Views/ForYouView.swift` | pass `settings.newReleaseKindFilter` to `ForYouGrid.tiles`. `tileMenu` uses `NewReleaseKinds.liveOutNow`. Add the filter to the grid's recompute key (`|\(releaseFeed?.revision)` line ~231) so switching mode updates the tile right away. |
| `PocketDJ/CarPlay/CarPlayForYou.swift` | `newReleaseItems` → `NewReleaseKinds.liveOutNow(... mode: services.settings.newReleaseKindFilter)`. `forYouTileModels` passes `newKind`. Expose `newReleaseEmptyNote` for the scene. |
| `PocketDJ/CarPlay/CarPlayScene.swift` | `pushForYou` `emptyText` = the model's filter note when present |
| `PocketDJ/Services/Recommendations/ReleaseFeedService.swift` | `uiFixtureKindEntries(nowMs:)` (900005/900006) |
| `PocketDJ/PocketDJApp.swift` | fixture seam: `PDJ_NEW_KIND` → `settings.newReleaseKindFilter`. `PDJ_NEW_FIXTURE_KINDS` → also seed `uiFixtureKindEntries` |
| `Tests/Unit/NewReleaseKindTests.swift` **(new)**, `Tests/UI/ForYouNewKindUITests.swift` **(new)**, additions to `CarPlayForYouTests`, the grid/tiles tests, and the settings tests | §7 |

XcodeGen picks up new files: run `xcodegen generate` after adding them.

### Android (local to the New screen + small settings additions; no `ForYouGrid.kt`, `ForYouTiles.kt`, `ReleaseFeedService.kt` or `BrowseGraph.kt` edits)
| File | Change |
|---|---|
| `screens/foryou/NewReleaseKind.kt` **(new)** | the same pure API as iOS (`ReleaseKindClass`, `NewReleaseKindFilter(raw)` + `from(raw)`, `NewReleaseKinds.classify/badge/arrange/hiddenNote`, extension `kindClass` on `ArtistReleaseEntry` and `LikedRelease`), plus `class KindFilteredForYouSource(service, mode): ForYouReleaseSource` |
| `screens/foryou/NewReleasesScreen.kt` | read the mode from `graph.settings.settings`. `arrange` per section and Liked. Group sub-header items. Footer item. `new-kind-empty` state. Badge via `badge()`. Show items in the `DropdownMenu` calling `graph.settings.setNewReleaseKind(raw)` on `scope`. `liveOutNow` from the arranged flat. Copy helpers in `NewReleasesPresentation` (`kindEmptyTitle`, `kindEmptyDetail`). |
| `screens/foryou/ForYouTilesScreen.kt` | line ~326: `KindFilteredForYouSource(it, mode)` in place of `ReleaseFeedForYouSource(it)`, keyed on the mode |
| `data/settings/AppSettingsStore.kt`, `data/settings/PrefKey.kt` | `newReleaseKind` field, key, setter (additive) |
| `app/src/test/.../screens/foryou/NewReleaseKindTest.kt` **(new)** + `NewReleasesPresentationTest` additions | §7.1 |

## 9. Known limits and follow-ups

- **One release per artist.** The feed caches each artist's *latest* release only (the
  `latest-release` view). If an artist put out an album and then, a week later, a single, the
  album is already gone from the cache, and "Albums only" can't show it. US1 is weakest for exactly
  the artists who keep releasing. Follow-up (its own design, touching `ReleaseFeedService` on both
  platforms): when a refresh replaces an entry whose previous release is still inside the 30-day
  window, keep it as `previousReleases` (≤3). It's out of scope here because it changes the feed's
  storage shape and the Android `ReleaseFeedService.kt` the parity program is near.
- The 3-vs-4-track boundary without durations (a 3-track long-form record reads as a single).
  Fetching durations would mean a per-release track expansion, which the feed deliberately never
  does on read.
- Syncing the choice across his devices: a small synced UI-prefs doc, if he asks.
- Android tile subtitle prefix ("Albums from …"): after `feat/android-parity2` lands
  (`ForYouTiles.kt`).
- Possible later fifth mode, "Singles, then albums". It's not asked for, and the enum makes it
  cheap.
