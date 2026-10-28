state: implemented

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
- Favorite tri-state / membership filter sections are not shown in the collection filter sheet (clause filters only); persisted state is sort keys + clauses.
- Recompute keyed on stored ids + inputs + catalog + `state.revision` (pocket/playlist).

## Questions for Levi
- Should Remove stay available while a collection is sorted/filtered (iOS does; the roadmap said hide)?

## Result
Implemented. Also updated two pre-existing tests that encoded "DATE_ADDED hidden" (SortEngineTest.forKind_exposesRegistrySubset, FilterEngineTest.dateAdded_offeredAsSongSort). Emulator step not run (shared emulator owned by integrator).
