state: reviewed

# COL-13 — Per-collection sort/filter

- [x] CollectionSortSettings (JSON map `collectionSortMapJson`, key `pdj.collection.<id>`)
- [x] CollectionSortFilter (pure resolve fns, state, sheets, buttons/menu items)
- [x] DATE_ADDED sort field offered + BrowseRows carries IndexSong.dateAdded
- [x] Source playlist / Pocket / Playlist detail wiring
- [x] Unit tests (CollectionSortFilterTest)
- [x] Full build + test verification (assembleDebug green; CollectionSortFilterTest adds 6 tests)

## Notes / deviations
- Touched outside owned files (minimal): `screens/browse/BrowseSort.kt` (DATE_ADDED now in `SortField.forKind`, so Browse/History sort sheets also offer it, as iOS) and `screens/browse/BrowseModels.kt` (`BrowseRows.songRows` sets `dateAdded`).
- Setlist detail NOT wired: iOS has no per-setlist sort/filter and SetlistDetailScreen is outside the owned files.
- Up/Down AND Remove menu items are hidden in a non-default order (roadmap acceptance). iOS keeps swipe-Remove there; flagged below.
- Favorite tri-state + membership filter now in the collection filter sheet (transient, read-time, not persisted, as iOS).
- Recompute keyed on stored ids + inputs + catalog + `state.revision` (pocket/playlist).

## Questions for Levi
- Should Remove stay available while a collection is sorted/filtered (iOS does; the roadmap said hide)?

## Result
Implemented. Also updated two pre-existing tests that encoded "DATE_ADDED hidden" (SortEngineTest.forKind_exposesRegistrySubset, FilterEngineTest.dateAdded_offeredAsSongSort). Emulator step not run (shared emulator owned by integrator).

## Review
fixes applied

- MAJOR selection on stored list while sorted/filtered -> fixed. Pocket/Playlist/Source select-all + payload now use the displayed (resolved) list via `CollectionSortFilter.selectableSongIds` / `selectableSongNodes`; pruneKey includes the resolved list. Tests: `selectionActsOnDisplayedRowsNotStored`, `playlistSelectionActsOnResolvedChapterNodes`.
- MINOR ledger row -> fixed (DONE, deviations, test count 4476 incl. +4 review tests).
- MINOR hydration -> fixed. Load failure leaves `loaded=false` (no overwrite); a late hydrate is ignored if the user already edited; `withEntry` leaves a corrupt blob untouched. Test: `hydrateDoesNotOverwriteEarlyEditAndCorruptBlobIsKept`.
- MINOR out-of-scope Browse edits -> fixed. BrowseModels/FilterEngineTest/SortEngineTest reverted; Browse/History still hide Date added. Only additive default-false `includeDateAdded` param on `SortField.forKind` and `BrowseSortSheet`, passed by the collection sheet.
- MINOR membership/favorite filter -> fixed. `CollectionBrowseInputs` carries favorite + membership (transient), applied via `ReadTimeFilters` from a `CollectionReadTime` snapshot; sheet shows both sections. Test: `favoriteAndMembershipFiltersApply`.
- NIT live play-count re-resolve and source-playlist id -> not done (optional; source id needs a stable source id not available on that screen).

Tests: 4476, 0 failures; assembleDebug green.
