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
| 13 Browser — albums (desktop) | `BrowseUITests.testLayoutToggleKeepsAlbumsVisible` | — | ✅ |
| 14–16 Edit album / audio / song | `SettingsUITests.testEditsExportImportPresent` | `EditSchemaTests` | ✅ |
| 18–19 Pockets — list / detail | `PocketsUITests` (create → open → rename → delete) | `CollectionsStoreTests` (pocket CRUD + cycle-guard + export/import) | ✅ |
| 20 Add to a pocket or playlist | — *(unit-covered)* | `CollectionsStoreTests` (`testRemembersLastAddTargetWithChapter`, …) | ✅ |
| 21–22 Playlists — list / template | `PlaylistsUITests` (create → chapter → rename → delete), `IndexPlaylistsUITests` | `CollectionsStoreTests` (playlist + sequences + moveNode + dup-from-songIds), `CatalogMergeTests` (index playlists) | ✅ |
| 23–24 Setlist — generated / track detail | `SetlistUITests` (Play → frozen set list) | `RealizeEngineTests`, `SeededRNGTests`, `HarmonicsUnitTests`, `CollectionsStoreTests` (realize-from-songIds) | ✅ |
| 27 Multi-source, collection filters & online search | `SettingsUITests.testAddSourceAppendsRow`, `testLoadAppleMusicAddsSource…` | `SettingsStoreTests`, `CatalogMergeTests`, `SigV4Tests` | ✅ |
| 1–4, 6–7 Star map / solar system | — | — | ❌ removed in native |
| 17 Delete-track confirm · 25 Collection Map/List · 28 Stream & download | — | — | ❌ PWA / server-side |

**Pockets/Playlists/Setlists (ch 18–24)** now have XCUITests
(`PocketsUITests`, `PlaylistsUITests`, `SetlistUITests`, `IndexPlaylistsUITests`) on top
of the unit coverage. The deep create/rename/delete + Play interactions are iOS-only
(`#if !os(macOS)`, like the other suites); macOS runs only the empty-state assertions.
The Setlist Play flow seeds a playlist via `PDJ_SEED_COLLECTIONS=1`.

---

## B. Change → targeted tests (the matrix selector)

Map the **changed source paths** (`git diff --name-only origin/main...HEAD`) to the
test classes to run. Always add the full unit bundle (`-only-testing:PocketDJTests`).

| Changed path (glob) | UI classes to run | Unit classes |
|---|---|---|
| `PocketDJ/Browse/**`, `Views/BrowseView.swift` | `BrowseUITests` | `BrowseStateTests`, `FilterEngineTests`, `SortEngineTests` |
| `Views/AlbumDetailView.swift`, `Views/SongDetailView.swift` | `BrowseUITests` | `DecodingTests` |
| `Views/Edit*View.swift`, `Models/EditSchema.swift`, `State/EditsStore.swift` | `SettingsUITests` | `EditSchemaTests` |
| `Views/SettingsView.swift`, `State/SettingsStore.swift` | `SettingsUITests`, `StorageUITests` | `SettingsStoreTests`, `CatalogMergeTests` |
| `Views/StorageView.swift`, `State/{StorageManager,PlayStatsStore}.swift`, `State/BurnStore.swift` (storage ops), `State/SessionFolders.swift` | `StorageUITests` | `BurnStoreStorageTests`, `StorageManagerTests`, `PlayStatsStoreTests`, `MixSessionRecordingsDeleteTests`, `BurnStoreFolderTests`, `SessionFoldersTests` |
| `Services/Search/**`, `State/OnlineSearchModel.swift` | `SettingsUITests` | `SigV4Tests` |
| `State/CollectionsStore.swift`, `Models/CollectionsSchema.swift`, `Views/{Pockets,Playlists,AddToCollection,SetlistDetail}*.swift` | `PocketsUITests`, `PlaylistsUITests`, `SetlistUITests`, `IndexPlaylistsUITests` | `CollectionsSchemaTests`, `CollectionsStoreTests`, `RealizeEngineTests` |
| `Performance/**` | *(none)* | `RealizeEngineTests`, `SeededRNGTests`, `HarmonicsUnitTests` |
| `Support/**` (Camelot, Genre, Fmt, Config) | *(none)* | `CamelotTests`, `GenreTests`, `FormatTests` |
| `Models/IndexModels.swift`, `State/AppModel.swift` | `BrowseUITests` | `DecodingTests`, `CatalogMergeTests` |
| **`PocketDJApp.swift`, `RootView.swift`, `Theme.swift`, `project.yml`, `Tests/UI/XCUIHelpers.swift`** | **ALL (shell/infra)** | **ALL** |

**Rule of thumb:** a change confined to one feature → that row's classes on **iPhone
only** (logic) + the relevant device if the change is platform-specific (a macOS
keyboard path → also macOS; an iPad layout → also iPad). A change to a **shell/infra**
row, or touching ≥3 feature rows → **run-all** (full matrix). When unsure, widen.

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
