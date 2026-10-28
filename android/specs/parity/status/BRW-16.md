state: reviewed

# BRW-16 Discover add: provisional catalog entries, album fan-out, supersede, Remove from Library
- [x] data/discover/DiscoverAddsStore.kt (entries + optional albums doc, iOS-shape lenient JSON `pocketdj-discover-adds.json`, idempotent adds, one batched album add, userRemove vs silent supersede remove, reloadFromDisk, split/splitAlbums, indexSong/indexAlbum/syntheticIndex)
- [x] data/discover/DiscoverAddState.kt (adding/partial/added; preparedCopies=false never spins)
- [x] data/discover/ProvisionalSource.kt (Discover IndexJson appended after real sources; supersede by appleMusicId; surviving tracks re-pointed at a superseded album's real twin)
- [x] CatalogRepository: provisionalSources / onSupersede / onAlbumsSuperseded hooks (merge order: real, Discover, synthetic Imported)
- [x] CollectionsStore.remapSongIds (playlist node trees, pocket songIds/repeats/sourceSongIds, setlist tracks)
- [x] screens/discover/DiscoverAddController.kt (song add, album fan-out accepted-only, REST-then-/album-tracks, removeFromLibrary, albumStates flow)
- [x] BrowseGraph wiring (store, ports, hooks, sync entry "discover-adds", reset hook, catalogAdd/catalogRemove activity)
- [x] SongDetailSheet "Remove from Library" (Discover + Imported rows); Discover album n/m capsule
- [x] Tests (see below)

## Files touched outside the owned list (all minimal/additive)
- data/collections/CollectionsStore.kt: +remapSongIds
- data/applemusic/AppleMusicApi.kt + AppleMusicApiModels.kt: +albumTracks / parseAlbumTracks (REST tier of the album fan-out)
- screens/discover/DiscoverAlbumResultsList.kt, DiscoverResultsList.kt: optional addStates param + n/m capsule
- data/reset/AccountDeletionService.kt (+ AccountDeletionTest key set): "discover-adds" cloud doc key (lockstep test)
- ActivityModels.kt: already carried CATALOG_ADD/CATALOG_REMOVE/libraryWrite/itemArtist; no edit needed

## Notes / deviations
- Library write outcome: Android has no membership probe, so an accepted Web API write is stored as "confirmed (web)" (the token History already treats as proof); no-MUT -> "skipped: no Apple Music connection"; failures -> "Apple Music write failed: ...".
- preparedCopies is recorded true only when the download intent AND a rip server is configured (iOS records true even serverless, which would spin at 0/n forever).
- Pre-release album refresh (iOS refreshProvisionalAlbums / needsRefresh / applyAlbumRefresh) is NOT ported (not in this package's acceptance); fields releaseDateMs/lastRefreshAtMs are carried so a later package can add it.
- Retry affordance ("Add to Apple Music again", recordAlbumLibraryWrite) has the store half only; no UI.
- Supersede prunes the provisional entry from the store (iOS behaviour); the "no deletion" guarantee applies to first-wins shadowing by merge order (same-id real row).
- Remove from Library also handles Imported rows (via ImportedSongsStore.remove); logs catalogRemove for both.
- Albums stay add-gated on a Music-User-Token in the Discover UI (BRW-15 behaviour, unchanged).

## Questions for Levi
- Should serverless (no import server) Discover album adds be allowed without an Apple Music sign-in? iOS allows; the BRW-15 UI still disables the album + without a MUT.

## Tests
New: DiscoverAddsStoreTest, DiscoverAddStateTest, SupersedeTest, DiscoverAddControllerTest, CatalogRepositoryTest, AlbumTracksParseTest.

JVM tests 4744 total, 0 failures; assembleDebug green (my new tests: ~56 across 6 files).

## Review
- MAJOR ledger row not updated -> fixed (BRW-16 row = PARTIAL with device-only + not-ported notes; BrwReviewFixesTest guards it).
- MINOR Remove from Library no confirm / main-thread write -> fixed (AlertDialog "Remove from Library?", removal on Dispatchers.IO).
- MINOR skipped token mismatch -> fixed ("Apple Music write skipped: no Apple Music connection"; test updated).
- MINOR onChanged re-fetched all sources -> fixed (CatalogRepository.remergeLocal, no fetch; Discover + Imported onChanged use it; refreshInternal with no loaded source still merges provisional/synthetic; tests added).
- MINOR album errored set in-memory only -> fixed (AlbumEntry.failedTrackIds persisted from the rip tracker; userRemove drops the track from its album's trackIds; tests).
- MINOR superseded album remap lasted one merge -> fixed (DiscoverAddsStore.supersedeAlbums persists remapped albumId on surviving entries; test).
- MINOR edits outside owned files (CollectionsStore.remapSongIds, AppleMusicApi*) -> rejected: remap needs the store's internal node/pocket/setlist mutators (no public equivalents), and the additions are additive and self-contained. FLAGGED to merge coordinator: COL-6/COL-9 may conflict in CollectionsStore.kt / AppleMusicApi.kt.
- NIT music-videos in album tracks -> fixed (only type "songs" kept; test).

fixes applied
