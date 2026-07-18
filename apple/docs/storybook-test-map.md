# Storybook ↔ Test map (native apps)

Traceability between the product story (`docs/STORYBOOK.md`) and the native test
suite (`apple/Tests/`), plus the **change → targeted tests** matrix that lets us run
only the relevant UI tests for a change instead of the whole matrix every time.

- **Run-all** (every test class × iPhone + iPad + macOS) is reserved for **CI** and for
  the **`/create-pr` judgment gate** (broad/cross-cutting/risky changes).
- **Unit tests are cheap** (~0.3s for the whole bundle) — **always run the full unit
  bundle**. Targeting only ever narrows the *UI* tests (each UI class is 20–100s/device).

The native app intentionally **dropped the star map / solar system**, so storybook
chapters 1–4, 6–7 (and 17, 25, 28) have **no native tests** — they're PWA-only or
server-side. Don't treat their absence as a coverage gap.

---

## A. Storybook chapter → tests that cover it

| Storybook chapter | UI test(s) | Unit test(s) | Native? |
|---|---|---|---|
| 5 Settings popout | `SettingsUITests` (all) | `SettingsStoreTests` | ✅ |
| 5a Settings ▸ Storage (manager: folders, deletes, soft cap) | `StorageUITests` | `BurnStoreStorageTests`, `StorageManagerTests`, `PlayStatsStoreTests`, `MixSessionRecordingsDeleteTests` | ✅ native-only |
| 8 Single-album view | `BrowseUITests.testAlbumNavigationShowsTrackTable`, `testSongDetailFromTrackTable` | `DecodingTests` | ✅ |
| 9 Song detail modal | `BrowseUITests.testSongDetailFromTrackTable` | — | ✅ |
| 10 Browser — albums | `BrowseUITests.testBrowserLoadsAlbums`, `testLayoutToggleKeepsAlbumsVisible` | `BrowseStateTests` | ✅ |
| 11 Browser — songs | `BrowseUITests.testSwitchToSongsListsTracks` | `BrowseStateTests` | ✅ |
| 12 Browser — filter & sort | `BrowseUITests.testFilterSheetOpens`, `testSortSheetOpens` | `FilterEngineTests`, `SortEngineTests` | ✅ |
| 12a History mode (⌘H) — timeline + group-by-song, Browser filters + Last-played sort + date range | `HistoryUITests` (timeline, group-by-song count, Last-played sort, filter sheet, paging) | `PlayHistoryStoreTests`, `PlayHistoryContextTests`, `HistoryEngineTests`, `SetlistPlayerTests` (attribution) | ✅ native-only |
| 12b CarPlay app — Browse (Playlists/Pockets/Albums→songs) · Play · Add-to · title/artist search | — *(CarPlay UI can't run headlessly — verify in the CarPlay Simulator; see `docs/carplay.md`)* | `CarPlayModelTests` (browse lists, songs, search, play routing, add-to) | ✅ iOS-only |
| 13 Browser — albums (desktop) | `BrowseUITests.testLayoutToggleKeepsAlbumsVisible` | — | ✅ |
| 14–16 Edit album / audio / song | `SettingsUITests.testEditsExportImportPresent` | `EditSchemaTests` | ✅ |
| 18–19 Pockets — list / detail | `PocketsUITests` (create → open → rename → delete) | `CollectionsStoreTests` (pocket CRUD + cycle-guard + export/import) | ✅ |
| 20 Add to a pocket or playlist | — *(unit-covered)* | `CollectionsStoreTests` (`testRemembersLastAddTargetWithChapter`, …) | ✅ |
| 21–22 Playlists — list / template | `PlaylistsUITests` (create → chapter → rename → delete), `IndexPlaylistsUITests` | `CollectionsStoreTests` (playlist + sequences + moveNode + dup-from-songIds), `CatalogMergeTests` (index playlists) | ✅ |
| 23–24 Setlist — generated / track detail | `SetlistUITests` (Play → frozen set list) | `RealizeEngineTests`, `SeededRNGTests`, `HarmonicsUnitTests`, `CollectionsStoreTests` (realize-from-songIds) | ✅ |
| 27 Multi-source, collection filters & online search | `SettingsUITests.testAddSourceAppendsRow`, `testLoadAppleMusicAddsSource…` | `SettingsStoreTests`, `CatalogMergeTests`, `SigV4Tests` | ✅ |
| 66 Performance tab (Studio) — Samples | `PerformanceUITests` | `StudioStoreTests`, `StudioEngineMathTests`, `StudioRenderTests`, `StudioMicRecorderTests`, `BeatMathTests` | ✅ native-only |
| 67 Performance — Loops | `PerformanceUITests` | `StudioStoreTests`, `StudioRenderTests`, `BeatMathTests` | ✅ native-only |
| 68 Performance — Sequencer | `PerformanceUITests` | `StudioEngineMathTests`, `StudioStoreTests` | ✅ native-only |
| 69 Performance — Instruments (MIDI · packs · score/SMF/PDF) | `PerformanceUITests` | `InstrumentPacksTests`, `ScoreQuantizerTests`, `SMFWriterTests`, `ScoreLayoutTests` | ✅ native-only |
| 70 Performance — Cues | `PerformanceUITests` | `CuePlumbingTests`, `StudioStoreTests` (cue max-8) | ✅ native-only |
| 71 Studio items in pockets / playlists (schema v5) | `PerformanceUITests` | `CollectionsStudioTests`, `CollectionsLossyDecodeTests` | ✅ native-only |
| 72 Settings ▸ Storage — studio folder locations | `PerformanceUITests`, `StorageUITests` | `StudioFoldersTests`, `StudioStoreTests` | ✅ native-only |
| 1–4, 6–7 Star map / solar system | — | — | ❌ removed in native |
| 17 Delete-track confirm · 25 Collection Map/List · 28 Stream & download | — | — | ❌ PWA / server-side |

**Pockets/Playlists/Setlists (ch 18–24)** now have XCUITests
(`PocketsUITests`, `PlaylistsUITests`, `SetlistUITests`, `IndexPlaylistsUITests`) on top
of the unit coverage. The deep create/rename/delete + Play interactions are iOS-only
(`#if !os(macOS)`, like the other suites); macOS runs only the empty-state assertions.
The Setlist Play flow seeds a playlist via `PDJ_SEED_COLLECTIONS=1`.

**Performance tab (Studio, ch 66–72)** carries **13 unit suites** — `StudioStoreTests`,
`StudioFoldersTests`, `BeatMathTests`, `CollectionsLossyDecodeTests`, `StudioEngineMathTests`,
`StudioRenderTests`, `StudioMicRecorderTests`, `InstrumentPacksTests`, `ScoreQuantizerTests`,
`SMFWriterTests`, `ScoreLayoutTests`, `CuePlumbingTests`, `CollectionsStudioTests` — all in the
always-run unit bundle. The **`PerformanceUITests`** class above is the intended UI suite
(tab + sub-tab nav incl. ⌘1..⌘5 via `typeKey` on macOS, seeded rows, rename/delete, cue slots,
storage sections; iOS-deep, macOS empty-state per convention), seeded via **`PDJ_SEED_STUDIO=1`**
(fixture sample/loop/pattern/cue rows + a bundled ~1 s audio fixture). **NOTE: `PerformanceUITests`
is not yet in `apple/Tests/UI/` — the Studio shipped with unit coverage only; the UI suite is
pending, so treat its rows here as coverage-intent until the class lands.**

---

## B. Change → targeted tests (the matrix selector)

Map the **changed source paths** (`git diff --name-only origin/main...HEAD`) to the
test classes to run. Always add the full unit bundle (`-only-testing:PocketDJTests`).

| Changed path (glob) | UI classes to run | Unit classes |
|---|---|---|
| `PocketDJ/Browse/**`, `Views/BrowseView.swift` | `BrowseUITests` | `BrowseStateTests`, `FilterEngineTests`, `SortEngineTests` |
| `Views/HistoryView.swift`, `State/PlayHistoryStore.swift` (History mode); its play-attribution touches `PocketDJApp.swift` hooks + `SetlistPlayer.swift` + `CollectionsStore.historyContext` | `HistoryUITests` | `PlayHistoryStoreTests`, `PlayHistoryContextTests`, `HistoryEngineTests`, `SetlistPlayerTests` |
| `PocketDJ/CarPlay/**` (CarPlay app), `Intents/IntentServices.swift` (playAlbum + shared) | *(none headless — CarPlay Simulator, see `docs/carplay.md`)* | `CarPlayModelTests`, `IntentServicesTests` |
| `Views/AlbumDetailView.swift`, `Views/SongDetailView.swift` | `BrowseUITests` | `DecodingTests` |
| `Views/Edit*View.swift`, `Models/EditSchema.swift`, `State/EditsStore.swift` | `SettingsUITests` | `EditSchemaTests` |
| `Views/SettingsView.swift`, `State/SettingsStore.swift` | `SettingsUITests`, `StorageUITests` | `SettingsStoreTests`, `CatalogMergeTests` |
| `Views/StorageView.swift`, `State/{StorageManager,PlayStatsStore}.swift`, `State/BurnStore.swift` (storage ops), `State/SessionFolders.swift` | `StorageUITests` | `BurnStoreStorageTests`, `StorageManagerTests`, `PlayStatsStoreTests`, `MixSessionRecordingsDeleteTests`, `BurnStoreFolderTests`, `SessionFoldersTests` |
| `Services/Search/**`, `State/OnlineSearchModel.swift` | `SettingsUITests` | `SigV4Tests` |
| `State/CollectionsStore.swift`, `Models/CollectionsSchema.swift`, `Views/{Pockets,Playlists,AddToCollection,SetlistDetail}*.swift` | `PocketsUITests`, `PlaylistsUITests`, `SetlistUITests`, `IndexPlaylistsUITests` | `CollectionsSchemaTests`, `CollectionsStoreTests`, `RealizeEngineTests`, `CollectionsStudioTests`, `CollectionsLossyDecodeTests` (v5 studio ids + lossy decode) |
| `Performance/**` *(realize engine — pockets→setlists; NOT the Performance tab, that's `Studio/**`)* | *(none)* | `RealizeEngineTests`, `SeededRNGTests`, `HarmonicsUnitTests` |
| `PocketDJ/Studio/**` (the Performance TAB — samples/loops/sequencer/instruments/cues) | `PerformanceUITests` | `StudioStoreTests`, `StudioFoldersTests`, `BeatMathTests`, `StudioEngineMathTests`, `StudioRenderTests`, `StudioMicRecorderTests`, `InstrumentPacksTests`, `ScoreQuantizerTests`, `SMFWriterTests`, `ScoreLayoutTests`, `CuePlumbingTests`, `CollectionsStudioTests`, `CollectionsLossyDecodeTests` |
| `Support/**` (Camelot, Genre, Fmt, Config; incl. `BeatMath.swift`, `Config.instruments*`) | *(none)* | `CamelotTests`, `GenreTests`, `FormatTests`, `BeatMathTests` |
| `Models/IndexModels.swift`, `State/AppModel.swift` | `BrowseUITests` | `DecodingTests`, `CatalogMergeTests` |
| `State/PlaybackSessionStore.swift`, `Playback/SetlistPlayer.swift`, `Playback/WidgetSync.swift`, `Views/NowPlayingPanel.swift` (durable playback session / sequencer / home deck) | `NowPlayingUITests` | `PlaybackSessionStoreTests`, `SetlistPlayerSessionTests`, `SetlistPlayerTests`, `NowPlayingQueueTests` |
| `PocketDJ/Mix/**` (Mix engine/decks/sessions/recorder UI), `State/MixDeckSessionStore.swift` (durable mix-deck session) | `MixDeckLayoutUITests`, `MixSessionsUITests`, `VUMeterAndCueUITests`, `MixDeckRestoreUITests` | `MixEngineTests`, `MixRecorderTests`, `MixSessionStoreTests`, `MixSessionRecordingsDeleteTests`, `RecordingBulletproofTests`, `MixDeckSessionStoreTests`, `MixEngineSessionTests` |
| **`PocketDJApp.swift`, `RootView.swift`, `Theme.swift`, `project.yml`, `Tests/UI/XCUIHelpers.swift`** | **ALL (shell/infra)** | **ALL** |

**Rule of thumb:** a change confined to one feature → that row's classes on **iPhone
only** (logic) + the relevant device if the change is platform-specific (a macOS
keyboard path → also macOS; an iPad layout → also iPad). A change to a **shell/infra**
row, or touching ≥3 feature rows → **run-all** (full matrix). When unsure, widen.

**The Performance-tab merge is a full-matrix run.** Adding the Studio tab touched the
**shell/infra** row — `RootView.swift` (the new `Section.performance` case + `pianokeys` icon
+ the ⌘P / ⇧⌘P / ⌥⌘P shadow-button reshuffle), `PocketDJApp.swift` (the app-scoped
`StudioStore` / `StudioMicRecorder` / engine `@State` + cross-wiring), and `project.yml` (the
new `Studio/**` files + the reworded mic usage string) — **and** it spans well over three
feature rows (Studio, Collections, Storage, Support, Playback). Either trigger alone mandates
**run-all** (every class × iPhone + iPad + macOS); this merge hits both.

---

## C. How to run a targeted set

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apple && xcodegen generate    # if the file list changed

# Example: a change under Performance/ + CollectionsStore → engine + collections, iPhone
xcodebuild test -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:PocketDJTests \
  -only-testing:PocketDJUITests/BrowseUITests       # only if a UI row applied
```

- `-only-testing:PocketDJTests` runs the **whole unit bundle** (cheap, always include).
- Add one `-only-testing:PocketDJUITests/<Class>` per UI class the matrix selected.
- macOS targeted run: `bash scripts/test-macos.sh` builds everything, then append the
  same `-only-testing:` flags to the `test-without-building` line (or pass them through).

Keep this file in sync when you add a test class or a storybook chapter (the
`/create-pr` docs gate covers the storybook; update the matrix here in the same pass).
