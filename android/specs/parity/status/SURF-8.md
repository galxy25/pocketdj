state: reviewed

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

## Review
- MAJOR Add-to chooser unreachable -> fixed: custom action returns SessionResult extras KEY_CUSTOM_BROWSER_ACTION_RESULT_BROWSE_NODE = `addto:<song>`; blind MRU add dropped; tap on a target row is the add. Test: addToAction_opensTheChooser_withoutAddingBlind.
- MINOR phone-only toasts -> fixed: failures also go out via MediaSession.sendError (carError); phone toast kept as secondary. Test: carVisibleFailures_reachTheSession.
- MINOR Continue row gating/main-thread decode -> fixed: hidden while a set is live and not held (iOS resumableSession); snapshot decoded on IO, cached, throttled refresh, root re-notified on change. Rejected sub-point: restoreIfIdle on connect (connect must not mutate; spec).
- MINOR counts include Studio ids -> fixed: resolved against catalog.songsById; SOURCE collection() looks up one playlist directly.
- MINOR amSignedIn race -> fixed: seeded synchronously (IO, 1.5 s cap) at construction; flips notify the lists.
- MINOR isRecent bind -> fixed: returns NOT_SUPPORTED before onConnect()/graph build.
- MINOR unbounded search cache -> fixed: latest-only, cleared in onDestroy, scan on Dispatchers.Default.
- MINOR no change notifications -> fixed: collections + catalog state observed, notifyLibraryChanged with real counts (also the touched collection after an add). Test: libraryChanged_notifiesWithRealItemCounts.
- NIT childCount/isOurs/Continue label -> left (optional).
Suite 4035 tests, 0 failures; assembleDebug green.

fixes applied
