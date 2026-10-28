state: in-progress

# COL-11 Favorites two-way Apple Music sync (opt-in) + owner-seed opt-in

- [x] FavoritesSyncSettings (favoritesTwoWaySync / applyOwnerFavoritesSeed, both default OFF)
- [x] FavoritesSyncService + FavoritesRemote seam (ApiFavoritesRemote over existing AppleMusicApi from SVC-15)
- [x] CollectionsGraph wiring: launch + foreground run, onChanged chained to pushNow
- [x] Settings "Favorites" section (toggle, Sync now, seed opt-in)
- [x] Tests: FavoritesSyncServiceTest, OwnerSeedOptInTest
- [ ] Full build/test green

## Notes / deviations
- Request construction (idsSongs, chunking, lovedIds parse, love body) already lives in AppleMusicApi (SVC-15) with tests in AppleMusicApiTest; not duplicated. The service tests assert the real URLs through MockWebServer.
- No debug base-URL override for the Apple Music API was added (AppleMusicApi takes baseUrl in its ctor; AppGraph.kt untouched). Emulator MockWebServer step needs that wiring later.
- Touched outside owned files: none beyond CollectionsGraph (owned).

## Questions for Levi
- Android has no owner gate; two-way sync is purely opt-in (default OFF). OK?
