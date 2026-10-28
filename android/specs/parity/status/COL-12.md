state: reviewed

# COL-12 Recently added virtual playlist
- [x] IndexSong.dateAdded + Settings count/clamp already existed (earlier packages); added IndexModelsDecodeTest.dateAddedOptional
- [x] RecentlyAdded.kt: pure derivation + RecentlyAddedBuilder (memo on catalog identity/limit/add signature, computeCount, hasItems gate, playlist())
- [x] Yours tab pinned "Recently added" section (off-main produceState) -> SourcePlaylistDetailScreen with id __pdj_recently_added__
- [x] CollectionsGraph.recentlyAdded; tests: 8 RecentlyAddedTest + 1 decode (3137 total, 0 failures)

## Notes
- In-app adds come from activity catalogAdd events (Android has no discoverAdds/imports stores). No non-owner own-library scoping (no owner-gate source tag wired).
- Settings row (CollectionsSection) already existed; no live "N songs" caption added.
- No files touched outside owned list besides IndexModelsDecodeTest.kt (additive).

## Questions for Levi
- None.

## Review
fixes applied
- Loading vs not-found (SourcePlaylistDetailScreen, PlaylistsScreen) -> fixed: detail shows "Loading…" until derivation finishes; Yours count is nullable, null suppresses the empty state and the row.
- catalogAdd input / later catalogRemove ignored -> fixed: addTimeOverrides takes latest add/remove per item, remove cancels add (test newerRemoveCancelsAdd). Plainly: until an Android add/import path emits catalogAdd, the list is effectively catalog-dateAdded-only (ledger row says so).
- iOS owner-gate dropped -> partially fixed: filterToOwnLibrary + isOwnLibrary params on addedAtBySongId/songIds/hasItems, flag in memo key (test ownLibraryScopeFiltersCatalogDates). Android has no owner identity so it passes false; ledger marked PARTIAL.
- Memo pins old catalog -> fixed: WeakReference key (test memoDoesNotPinOldCatalog).
- Ledger row -> fixed (PARTIAL). Emulator step not run (emulator owned by integrator).
- NIT row icon + testTag -> fixed (ListItem, History icon, "recently-added-row"). Settings live "N songs" caption not added.
Tests: 3140 total, 0 failures (was 3137; +3).
