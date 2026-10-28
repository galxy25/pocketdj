state: implemented

COL-4 AddToActions + Add-to sheet parity + 'Add to Playlist' context menu.
- [x] data/collections/FuzzyMatch.kt (iOS port) + FuzzyMatchTest (13)
- [x] screens/collections/AddToActions.kt (AddToItem incl. Songs batch, recent/suggested/quickTargets, membership w/ one Set per row, add/remove/toggle, AddToSheetParams.tapOutcome)
- [x] AddToCollectionSheet: fuzzy search field (searchFirst focuses), Suggested (nullable seam CollectionsGraph.collectionSuggestions), Recent, A-Z pockets/playlists, ✓ tap removes, no snackbar, onAdded + stayOpenAfterAdd (defaults unchanged: add dismisses), Songs item header
- [x] AddToPlaylistMenu.kt (top-5 ✓ toggles + More… => sheet searchFirst), hooked in BrowseScreen long-press
- [x] Tests: AddToActionsTest (7), AddToSheetParamsTest (4)

Deviations / notes:
- Compose has no nested menus: "Add to Playlist" submenu renders as a compact dialog on long-press (Browse rows only; PlaylistsComponents.kt untouched).
- Search field sits above the list (not bottom) even for searchFirst.
- Suggested seam is unwired (no Android rec engine yet) => no Suggested section until a rec package sets CollectionsGraph.collectionSuggestions.
- Album remove from a playlist uses store.removeNode per direct-child album node (no batch album API).
- Emulator steps not run (emulator owned by integrator).
- No files touched outside owned list.

## Questions for Levi
None.
