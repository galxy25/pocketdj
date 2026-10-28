state: implemented

# BRW-14 New releases feed + screen + release streaming

- [x] ReleaseFeedModels.kt (ReleaseFeedPolicy, ReleaseFeedSeed, ReleaseStatus, ArtistReleaseEntry, iOS-shape document codec, ArtistsCatalogResponse parser, ReleaseFeedWiring)
- [x] ReleaseFeedService.kt (transport iface + OkHttp AppleMusicReleaseTransport, retry/backoff, 2-in-flight global guard, seed, recheck, emptyReason, persisted cache, ForYouReleaseSource adapter)
- [x] AlbumOwnership.kt (AlbumOwnership + OwnedCatalogIndex + ReleaseOwnershipProbes)
- [x] ReleaseStreaming.kt (am:<storeId> items, <=25 releases, concurrency 4, ordered)
- [x] NewReleasesScreen.kt (Out now / Coming soon, thumbs scope `new`, recheck menu, play/shuffle, empty states)
- [x] BrowseGraph wiring (releaseFeed lazy, ownership index off-main, seed + on-play trigger)
- [x] Tests
- [x] Full suite + assembleDebug: 5026 tests, 0 failures (71 new: ReleaseFeedPolicyTest 10, ReleaseFeedModelsTest 9, ReleaseFeedServiceTest 20, AlbumOwnershipTest 11, ReleaseStreamingTest 8, NewReleasesPresentationTest 8 + counted in suite); assembleDebug green
- Device-only: playing an unowned release (Apple Music DRM playback). Emulator step (New tab after plays) not run - emulator owned by integrator.

## Files touched outside the owned set (minimal, additive)
- data/catalog/CatalogRepository.kt: `indexArtists()` accessor (the merged catalog drops the artists table; ownership alias route + artist-id join need it)
- screens/history/HistoryScreen.kt: NEW route opens NewReleasesScreen
- screens/foryou/ForYouTilesScreen.kt: grid is given the release source (New count / Coming soon / empty note)

## Deviations / notes
- Rows open the Apple Music album page (ACTION_VIEW music.apple.com/us/album/<id>); Android has no AlbumPreview screen for unowned AM albums yet.
- Release expansion uses AppleMusicApi.albumTracks only; the rip-server `/album-tracks` second tier is not ported.
- Tile long-press Play/Shuffle for the New tile stays disabled (ForYouGrid.songIds(NEW) is empty by BRW-12 design); play lives on the New screen.
- Transport is a small OkHttp class (not AppleMusicApi) so 5xx/429 retry belongs to the service exactly as iOS; honours AppleMusicApi.debugBase in debug builds.
- Artist-id resolution for plays uses the indexed `artists` table by normalized name (whole credit, then each name in the credit).
- No UI-test fixture wiring (uiFixtureEntries exists as a seam only).

## Questions for Levi
None.
