state: implemented

# BRW-15 Discover tab (Apple Music catalog search ∥ rip-server /search)
- [x] DiscoverModels.kt (DiscoverHit/AlbumHit/AlbumTrack, DiscoverMerge: term/merge/refine/mapping, DiscoverAddWording)
- [x] DiscoverSearchModel.kt (DiscoverQueryRunner: 400 ms debounce, parallel REST + /search, states NoSources / Unavailable)
- [x] DiscoverResultsList.kt (songs list, DiscoverPane host with Songs|Albums scope + artist refine) and DiscoverAlbumResultsList.kt (tap = inline /album-tracks list)
- [x] RipServerClient: searchSongs / searchAlbums / albumTracks (/search only + /album-tracks)
- [x] SearchMode.DISCOVER (persisted "discover"; older builds parse as device), 4th "Discover" segment in BrowseScreen, hides layout/sort/filter/mode controls; picking a kind returns to device
- [x] BrowseGraph.discoverAddSong/discoverAddAlbum hooks (DISC-2 replaces) + hasMusicUserToken
- [x] Tests: DiscoverMergeTest, DiscoverSearchModelTest, SearchModeDiscoverTest, RipServerClientTest (+6 discover cases)

JVM tests 4493 total, 0 failures; assembleDebug green.

## Notes / deviations
- Edited existing BrowseSessionPersistenceTest: "discover" was its unknown-string sample, now a known mode ("holodeck").
- Play Next/Last omitted (no queue API on Discover rows; hits have no catalog song to enqueue). Tapping a song row does nothing; ＋ only.
- Default ＋ (until DISC-2): library write via AppleMusicApi.addToLibrary when a MUT exists + requestRip(amrec_<id>). No provisional catalog rows, no album fan-out, no progress n/m.
- Edition (explicit-preference) re-rank not ported. ripped/url from the local manifest not passed for REST rows (server rows carry it).
- Album "preview" is an inline expansion of /album-tracks, not a separate screen.
- Models live in screens/discover (wire types), imported by RipServerClient.
- No docs/ARCHITECTURE-ANDROID.md edit (integrator).

## Questions for Levi
- None.
