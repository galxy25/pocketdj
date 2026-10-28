state: merged

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

## Review
fixes applied
- MAJOR BrowseGraph requestRip without metadata -> fixed: new `RipServerClient.requestRip(songId,title,artist,appleMusicId,lengthMs)` + extended `ripBody`; discoverAddSong uses it. Tests: RipServerClientTest (body carries title/artist/appleMusicId/lengthMs; empty metadata omitted).
- MAJOR ripped rows show Added, no play -> PARTIAL: ripped rows now show a distinct "Ripped" check (no longer "Added"). Play/Play Next/Last from Discover is NOT wired (no Discover-row play path in this package); left for DISC-2/integrator.
- MINOR album add / no feedback -> fixed: album ＋ disabled with "Sign in to Apple Music" help when no MUT; failed adds (song and album) show iOS "Add failed — the import server didn’t accept the request."
- MINOR explicit re-rank -> fixed: `DiscoverExplicitRanking` (pure, stable) applied at display using EditionSettings (null -> clean first); DiscoverExplicitRankingTest.
- MINOR stale canAdd -> fixed: derived from `settings.settings` flow.
- MINOR NoSources on transient REST failure -> fixed: `DiscoverRestResult.failure`; missing dev token stays NoSources, network/429/etc. -> Unavailable with the failure text. Tests added.
- NIT 2xx decode "Search failed (200)." -> fixed ("Search failed."), test added.
- NIT immediate submit not wired -> not done (optional): Browse field has no IME-search hook; debounce stays 400 ms. BrowseSessionPersistence.kt edit flagged for the integrator (only the "discover" mode token + its test sample).

JVM tests 4502 total (+9), 0 failures; assembleDebug green.
