state: implemented

# ANS-GAP-3 status

- [x] Pre-release album refresh: DiscoverAddsStore.needsRefresh/applyAlbumRefresh/placeholder matchers; DiscoverAddController.refreshProvisionalAlbums (+ DiscoverRipPort.albumExpansion, default impl); new tracks of download-intent albums get rips
- [x] "Add to Apple Music again": DiscoverRetryRow.kt (AlbumLibraryWriteRetry gate + notice + composable), DiscoverAddController.retryAlbumLibraryWrite, wired in album results rows
- [x] enqueueAudioAnalysis producer: RecommendationService.scheduleAudioAnalysis, called after feed.refresh in ForYouInputsFactory.refresh
- [x] Tests: DiscoverRetryTest (9), AudioAnalysisEnqueueTest (4); suite 5499 tests, 0 failures; assembleDebug green

## Files touched outside owned list (minimal, additive)
- screens/discover/DiscoverAlbumResultsList.kt, DiscoverResultsList.kt (retry row + refresh trigger), di/BrowseGraph.kt (retry + refresh + albumExpansion), screens/foryou/ForYouTilesScreen.kt (producer call)

## Deviations
- iOS refreshes at launch/foreground; Android triggers it when the Discover tab is shown (no app-level foreground hook found). Retry row appears on album result rows (no Android AlbumPreview/AlbumDetail screen for provisional albums).

## Questions for Levi
- None blocking. Should the pre-release refresh also run at app launch independent of opening Discover?
