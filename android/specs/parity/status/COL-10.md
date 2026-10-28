state: merged

# COL-10 Favorites store + toggle + Browse tri-state + activity wiring

- [x] FavoritesModels.kt (FavoriteEntry, FavoritesDocument iOS shape, FavoriteFilter ANY|FAVORITE|NOT, FavoritesAccess = FavoriteSeam shape)
- [x] FavoritesStore.kt (tombstones, favoriteIds, revision, onChanged user-only, applyRemote/applySeed/importMerging/remapSongIds, coalesced saves, flushNow, export)
- [x] favoriteActivityRecorder -> heart/unheart rows with live-catalog title/artist
- [x] CollectionsGraph: lazy `favorites`, `favoriteAccess` (resolves AM id from catalog; bind PB-2 FavoriteSeam to it), ON_STOP flush
- [x] FavoriteToggle.kt + CollectionTrackRow(favoriteSongId) wired at Pocket/Playlist/SourcePlaylist/Setlist call sites
- [x] BrowseFilters.favorite (transient, not in snapshot) + BrowseRows.filteredSongs(favoriteIds) via BrowseEngine.applyFavorites
- [x] StorageService Category.FAVORITES (display-only)
- Tests: 826 run, 0 failures; +14 (FavoritesStoreTest 10, FavoritesActivityTest 4).

## Touched outside owned files (minimal/additive)
- di/AppGraph.kt: one arg `favoritesFile` to StorageService.
- screens/settings/StorageScreen.kt: FAVORITES meta arm (exhaustive when).
- BrowseEngine.kt: applyFavorites + import.
- Playlist/Pocket/SourcePlaylist/SetlistDetailScreen.kt: one line each passing favoriteSongId.

## Not done (outside owned files; follow-up)
- Browse UI: ♥ in Browse song rows, SongDetailSheet, AlbumDetailScreen track rows, and the filter-sheet control for the tri-state; BrowseScreen must pass `favorites.favoriteIds` into filteredSongs. FavoriteToggle is ready to drop in.
- Backup zip / profile-sync registration of the favorites file (SURF/COL sync entries).

## Questions for Levi
- None.

## Review
fixes applied
- MAJOR Browse favorite filter/♥ dead in app -> fixed. BrowseScreen SONGS arm now runs `BrowseRows.songResults` (filterSort + applyFavorites against live `favoriteIds`); revision folded into produceState keys only while the filter is active (not in resultsKey). Tri-state control added to BrowseFilterSheet (song mode); FavoriteToggle on BrowseSongRow, SongDetailSheet, AlbumTrackRow; badge/empty-state counts kind-gated. Test: BrowseEngineTest.productionSongPipelineAppliesLiveFavoriteTriState.
- MINOR ledger row -> fixed (PARTIAL with open items).
- MINOR toggle/isFavorite stale + lock nesting -> fixed. toggle/isFavorite read the locked internal set; onChanged hooks queued inside withCoalescedSaves and fired after lock release. Tests: toggleTwiceInsideCoalescedBlockFlipsBack, onChangedFiresAfterLockReleasedForCoalescedToggles.
- MINOR main-thread disk read in FavoriteToggle -> fixed: CollectionsGraph warms `favorites` on Dispatchers.IO at construction.
- MINOR remapSongIds no caller -> recorded as follow-up (Android has no Discover/amrec_ supersede path; wire with CollectionsStore remap). Backup-zip/profile-sync registration also recorded as open in the ledger.
- NIT dirty never cleared -> fixed: flushNow skips inline write when writer.appliedVersion >= saveVersion.
- Tests: 829 run, 0 failures (+3 vs 826).
