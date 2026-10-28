state: implemented

# SURF-8 - Android Auto: MediaLibraryService browse tree

- [x] auto/AutoBrowseTree.kt: pure tree (AutoId codec, AutoNode, AutoLibraryData port): root Continue (held only) / Playlists / Pockets; user then source playlists (badge subtitle); Play all / Shuffle all then songs (cap 200); unplayable rows non-playable "Not available here"; "No songs" / "No x yet" placeholders; single "Loading…" while catalog cold; search (collections then songs)
- [x] auto/AutoLibraryCallback.kt: pure decisions (connect warm-up once, select dispatch, Add-to chooser, custom action, catalog-ready notify) + MediaItem mapping (content-style hints, https art, supportedCommands)
- [x] auto/AutoArtwork.kt (https-only art), auto/AutoAddTargets.kt (pockets then playlists, never Now Playing)
- [x] auto/AppAutoServices.kt: production ports (AppAutoData / AppAutoPlayer / AppAutoAddSink) over CollectionsStore, catalog, rips, PlaybackController.playSetlist(startEntryIndex), ShellActions.ensureReady + onboarding veto
- [x] PlaybackService: MediaSessionService -> MediaLibraryService; library overrides (root/item/children/search/searchResult), Add-to custom command + setCommandButtonsForMediaItems, onSetMediaItems intercepts our browse ids (runs the sequencer path, refuses the controller set, same contract as SearchPlayBridge which is kept)
- [x] Manifest: MediaLibraryService + MediaBrowserService intent filters, com.google.android.gms.car.application meta-data; res/xml/automotive_app_desc.xml (media)
- [x] Tests: AutoBrowseTreeTest 16, AutoLibraryCallbackTest 12, AutoIdCodecTest 5, AutoAddTargetsTest 5, AutoArtworkTest 2 = 40 new; suite 4033 total, 0 failures; assembleDebug green

## Files touched outside owned list
- None beyond the owned list (extra test files AutoIdCodecTest/AutoAddTargetsTest/AutoArtworkTest/AutoTestFakes and auto/AppAutoServices.kt are new).

## Notes / deviations
- Warm-up: a cold car connect calls `catalogRepository.loadIfNeeded()` once (cache seed first; it is the app's normal cold-start load, single-flight) from onGetLibraryRoot only; the tree itself reads nothing until the catalog exists. If strict "no network refresh on connect" is wanted, a cache-only seed entry point on CatalogRepository is needed (not in owned files).
- Custom "Add to…" browser action adds to the most recent add target (else first pocket) with a toast; the full chooser is reachable as browsable node `addto:<song>` but the host cannot be navigated to it from a custom action result (device-only: verify on DHU 2.x).
- Selecting a row refuses the controller's own set (failed future) after starting the sequencer path; the host may flash an error on some head units (device-only).
- Pocket/playlist song counts resolve through the store per listing (no memo).
- PlayAll history/origin comes from CollectionsStore.playNowPlaylist/Pocket, so tags match the in-app path. startAt uses the index in the Now Playing set (1:1 with queue entries).
- Not run: DHU/emulator steps, voice. docs/ARCHITECTURE-ANDROID.md untouched (integrator).

## Questions for Levi
- Is a cold-start `loadIfNeeded()` (cache then conditional refresh) acceptable when Auto connects before the app was opened, or should connect be cache-only?
