state: reviewed

- [x] AutoForYou (tiles via ForYouGrid.tiles on the cached snapshot, rel: release rows, cold-cache note, play plans)
- [x] AutoId: tab:foryou, fy:<tile>, fyall/fyshuf, fyrow, fynote; tree wiring + ROOT_CHILDREN_LIMIT folding (Continue -> top of Playlists)
- [x] Callback select/add-to; AutoPlayer.playForYouSongs (playSongIds -> beginPlayback) / playReleases
- [x] AppAutoForYouSource + PlaybackService wiring (root hint limit, feed-revision re-notify)
- [x] Tests: AutoForYouTest (22). Full suite 6670 tests, 0 failures; assembleDebug green.

## Summary
Android Auto gets a For You tab built only from the cached ForYouFeedStore snapshot (never refresh/rank on connect). Tiles are ForYouGrid.tiles (same as the phone); New lists out-now releases as rel:<storeId> rows (count = playable rows); cold cache is one note row. Tile/Play all/Shuffle all/row play via ForYou plans; rows play from there on; songs get existing pdj.addTo. Root limit hint (androidx.media.MediaBrowserCompat.Extras.KEY_ROOT_CHILDREN_LIMIT) folds Continue into Playlists when root would overflow.

## Deviations / touched outside owned files
- PlaybackService.kt: additive (forYou arg, root-limit hint read, feed revision collector).
- AutoBrowseDebug.kt: pdj.autoPick accepts fy:<id> (searched under the For You tab).
- AppAutoServices.kt (shared touchpoint): AppAutoForYouSource + AppAutoPlayer overrides.
- AutoPlayer gained two default-throwing methods (existing fakes unaffected).
- Limit literal used as a string constant (media-utils not a dependency). assembleRelease not run (no manifest/gradle/proguard/library changes).
- Release-row tap plays that release alone; New tile uses sequencer.play with RUN_TAG (no feedback scope), as phone.

## Questions for Levi
None.

## Review
- MINOR root-limit shared field -> fixed: setRootLimit only ever lowers (null/looser hints ignored); PlaybackService sets it BEFORE onConnect. Test rootLimit_onlyLowers_*.
- MINOR re-notify gaps -> fixed: AppAutoForYouSource.changes combines feed revision + feedback state + release-feed revision (initial value no longer dropped); collector posts to main; callback tracks opened fy:<tile> parents and re-notifies them with the tabs. Test openForYouTile_isReNotifiedWithTheTabs.
- MINOR New tile vs live release feed -> fixed/verified: outNowReleases reads only persisted state (releaseFeed.outNow + feedback); tile count and rows come from the same list. Test newTile_countAndRowsComeFromTheSameReleaseList.
- NIT playForYouSongs ordering -> rejected as unit-testable (needs AppGraph); stays device-only, documented in AutoPlayer KDoc.

fixes applied. Suite 6673 tests, 0 failures (was 6670); assembleDebug green.
