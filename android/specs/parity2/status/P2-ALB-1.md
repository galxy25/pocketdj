state: in-progress

# P2-ALB-1 AlbumFileTimeline + SegmentOverrides + burned side-file playback

- [x] AlbumFileTimeline.kt, SegmentOverrides.kt (pure, iOS port)
- [x] CatalogRepository.segmentOverrides StateFlow, derived in buildCatalog (every publish / reapplyEdits / remergeLocal)
- [x] RipsRepository.effectiveStartMs, BurnStore.startMs apply override (only when item has a start)
- [x] ServicesGraph.burnedFirst uses localUrlForPlayback (side file + window, isCut=false); PreferringCut stays for Mix/Studio
- [x] Tests: AlbumFileTimelineTest, SegmentOverridesTest, BurnedSideFileTest
- [ ] Full build green

## Deviations / files outside owned set
- di/AppGraph.kt: 3-line additive wiring of RipsRepository.segmentOverrides provider (ServicesGraph can't reach it safely at init).
- PlayResolver got an optional `startOf` hook (default = manifest start); streaming callers (RowSourceResolver/ManifestRowResolver, MixGraph etc.) are NOT yet switched to effectiveStartMs: those files belong to other packages. Follow-up for the integrator.
- BurnedRowResolver.from now takes `playbackFile` instead of `preferringCut`.

## Questions for Levi
None.
