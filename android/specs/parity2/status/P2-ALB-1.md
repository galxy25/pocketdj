state: merged

# P2-ALB-1 AlbumFileTimeline + SegmentOverrides + burned side-file playback

- [x] AlbumFileTimeline.kt, SegmentOverrides.kt (pure, iOS port)
- [x] CatalogRepository.segmentOverrides StateFlow, derived in buildCatalog (every publish / reapplyEdits / remergeLocal)
- [x] RipsRepository.effectiveStartMs, BurnStore.startMs apply override (only when item has a start)
- [x] ServicesGraph.burnedFirst uses localUrlForPlayback (side file + window, isCut=false); PreferringCut stays for Mix/Studio
- [x] Tests: AlbumFileTimelineTest, SegmentOverridesTest, BurnedSideFileTest
- [x] testDebugUnitTest + assembleDebug green: 5794 tests, 0 failures (14 new: 7 timeline, 5 overrides, 2 side-file). No manifest/gradle change, so no assembleRelease.

## Deviations / files outside owned set
- di/AppGraph.kt: 3-line additive wiring of RipsRepository.segmentOverrides provider (ServicesGraph can't reach it safely at init).
- PlayResolver got an optional `startOf` hook (default = manifest start); streaming callers (RowSourceResolver/ManifestRowResolver, MixGraph etc.) are NOT yet switched to effectiveStartMs: those files belong to other packages. Follow-up for the integrator.
- BurnedRowResolver.from now takes `playbackFile` instead of `preferringCut`.

## Questions for Levi
None.

## Review
- MAJOR burned window truncated at catalog length -> fixed: BurnedHit/burnedLocalFile/BurnedRowResolver.from take an end provider; ServicesGraph wires AlbumFileTimeline.forSong(...).endMs (detected end + 15 s grace, or edited end), falling back to start+duration. Test: BurnedTimelineEndTest.
- MAJOR effectiveStartMs dead code -> fixed: PlaybackController passes it as startOf to PlayResolver.resolveBurnedFirst (both sites) and to ManifestRowResolver (sequencer stream rung, new startOf param). Mix/Studio/Cues use per-song cut/other paths, not the manifest start. Tests: streamStartHonorsEditedBoundary, manifestRowResolverUsesStartOf.
- MINOR buildCatalog side effect -> fixed: buildCatalog returns Built(catalog, overrides); overrides published next to each _state.update under publishLock.
- MINOR AppGraph wiring split -> fixed: both providers are now constructor params (RipsRepository, BurnStore) wired at their single construction sites. AppGraph.kt is still edited (one param line): integrator conflict risk flagged.

fixes applied. Tests: 5798, 0 failures (+4); assembleDebug green.
