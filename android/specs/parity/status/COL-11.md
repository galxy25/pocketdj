state: merged

# COL-11 Favorites two-way Apple Music sync (opt-in) + owner-seed opt-in

- [x] FavoritesSyncSettings (favoritesTwoWaySync / applyOwnerFavoritesSeed, both default OFF)
- [x] FavoritesSyncService + FavoritesRemote seam (ApiFavoritesRemote over existing AppleMusicApi from SVC-15)
- [x] CollectionsGraph wiring: launch + foreground run, onChanged chained to pushNow
- [x] Settings "Favorites" section (toggle, Sync now, seed opt-in)
- [x] Tests: FavoritesSyncServiceTest, OwnerSeedOptInTest
- [x] Full build/test green: 4889 tests, 0 failures (+16 new: FavoritesSyncServiceTest 12, OwnerSeedOptInTest 4); assembleDebug OK

## Notes / deviations
- Request construction (idsSongs, chunking, lovedIds parse, love body) already lives in AppleMusicApi (SVC-15) with tests in AppleMusicApiTest; not duplicated. The service tests assert the real URLs through MockWebServer.
- No debug base-URL override for the Apple Music API was added (AppleMusicApi takes baseUrl in its ctor; AppGraph.kt untouched). Emulator MockWebServer step needs that wiring later.
- Touched outside owned files: none beyond CollectionsGraph (owned).

## Questions for Levi
- Android has no owner gate; two-way sync is purely opt-in (default OFF). OK?

## Review
fixes applied

- MAJOR launch/foreground sync ungated -> fixed: `FavoritesSyncService.runIfReady()` + `ready` gate (onboarding complete && catalog loaded) on launch/foreground triggers; extra run when catalog first becomes non-null; `lastSyncedAtMs` only stamped when pull actually ran. Tests: runIfReadyNotReadyMakesNoRequestsAndNoStamp, emptyCatalogPullDoesNotStampLastSynced.
- MINOR Settings run cancelled on leaving screen -> fixed: toggle-ON and "Sync now" run on app.appScope (IO).
- MINOR star not best-effort per chunk -> fixed: push() chunks at 250, runCatching per chunk. Test: failedStarChunkDoesNotSkipLaterChunks.
- MINOR one rejected rating blocks queue -> fixed: DELETE 404 = pushed; per-entry failures continue (error reported at end); NeedsUserToken/RateLimited stop the pass. Tests: delete404CountsAsPushed, oneRejectedEntryDoesNotBlockTheQueue.
- MINOR ledger row -> fixed: docs/ARCHITECTURE-ANDROID.md COL-11 row now PARTIAL (JVM).
- NIT duplicate launch pass -> fixed: removed the unconditional launch run; ON_START observer + first-catalog trigger remain.
- Build/test: 4894 tests, 0 failures (+5); assembleDebug OK.
