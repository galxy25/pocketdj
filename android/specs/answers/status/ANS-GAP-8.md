state: merged

# ANS-GAP-8 - COL-12/BRW-7 gaps (catalogAdd producers + timeline artwork)

- [x] Discover adds already emitted catalogAdd (DiscoverAddsStore.onUserCatalogAdd, existing) - unchanged
- [x] Recognizer: RecognitionAddController.onCatalogAdd fires on a confirmed library add (libraryWrite "confirmed"); wired in BrowseGraph
- [x] Import: ImportedSongsStore.onUserCatalogAdd (user add path only, never cloud pull), iOS granularity (fresh albums + loose songs), planner RecentlyAdded.importCatalogAdds; wired in CollectionsGraph (libraryWrite null, as iOS)
- [x] Timeline rows: ActivityRowUi.artUrl via activityArtUrl (song -> album art, album -> own), rendered with the Coil-backed ArtThumb (shared Coil cache), not AlbumArtworkStore
- [x] RecentlyAddedProducerTest (5 tests); full suite 5572 tests, 0 failures; assembleDebug green

Files touched outside owned list (minimal, additive): ImportedSongsStore.kt, AppleMusicRecognition.kt, BrowseGraph.kt, CollectionsGraph.kt, HistoryScreen.kt.
Owner gate unchanged (Q56). No manifest/proguard changes, so assembleRelease not run.

## Questions for Levi
None.

## Review

- MAJOR imported-album tracks missing from Recently added -> fixed: ImportedSongsStore.indexSong sets dateAdded from addedAtMs; new test importedAlbumTracks_appearInRecentlyAdded drives store.add + MergedCatalog + RecentlyAddedBuilder.songIds.
- MINOR timeline artwork -> fixed: ActivityRowUi carries artAlbumId; ActivityRow renders shared AlbumArt (on-demand AM-Local art + candidate fallback), placeholder otherwise.
- MINOR recognizer libraryWrite token -> fixed: uses LibraryWrite.CONFIRMED_WEB. Routing through DiscoverAddsStore not done (documented: amrec_ event is not a catalog citizen until a rip/index lands it).
- NIT end-to-end test -> fixed (same test as MAJOR).

fixes applied. Suite: 5573 tests, 0 failures; assembleDebug green.
