state: implemented

# SURF-5 - ShellActions facade + MixFacade seam + Assistant media search + shortcuts

- [x] shell/ShellActions.kt: playPlaylist/playPocket/playSong/playAlbum/playSongIds (return display name), open/search, startAutoMix (single + two-deck)/pause/resume; onboarding veto on every mutating call (SetupGate), ensureReady (manifest kick once, disk-cache seed only, bounded 10 s on a true first launch)
- [x] ShellActionException with iOS strings verbatim; MixUnavailable "Auto-Mix isn't available yet" while mixFacade == null
- [x] shell/MixFacade.kt seam (Mix area assigns `shellGraph.shellActions.mixFacade`)
- [x] assistant/MediaSearchHandler.kt: MEDIA_PLAY_FROM_SEARCH parse + resolver (exact -> normalized -> token coverage, tie -> lastPlayedAt, kind hint "pocket"/"playlist", shuffle word, filler stripped), no match -> BrowseSearch; MediaSearchIntentHandler also handles static-shortcut ACTION_OPEN_TAB; SearchPlayBridge for PlaybackService
- [x] assistant/ShortcutsPublisher.kt: ranking by lastPlayedAt, cap, excludes NOW_PLAYING ids, 1 s debounce, distinct; ShortcutManagerCompat sink
- [x] res/xml/shortcuts.xml (3 static: Collections, Browse, Mix) + res/values/shortcut_strings.xml
- [x] ShellGraph wiring: shellActions, DeepLinkSeams.playItem (pocketdj://play/... now plays), handlers, publisher started when handlers are first read
- [x] PlaybackService.onSetMediaItems search hook (answers with the current queue so the sequencer's run is not cleared)
- [x] Tests: ShellActionsTest (12), MediaSearchHandlerTest (11), ShortcutsPublisherTest (5) = 28 new; suite 1934 total, 0 failures; assembleDebug green

## Files touched outside owned list
- AndroidManifest.xml (additive): MEDIA_PLAY_FROM_SEARCH intent-filter on MainActivity; replaced the stale "SURF-9" comment above the shortcuts meta-data.
- ShellGraph.deepLinkHandlers lazy now has side effects (assign seams, start the publisher); AppGraph.init reads it once via IntentSink.install.

## Notes / deviations
- Setlist deep links (`pocketdj://play/setlist/<id>`) still route to the Setlist screen with autoplay (existing behaviour), not through ShellActions.
- Dynamic shortcut cap = launcher max per activity minus 3 static entries.
- Song-focus voice search builds a candidate per catalog song on demand (only when focus=song).
- Mix: nothing implements MixFacade yet; MIX package must assign it.
- Emulator steps (adb MEDIA_PLAY_FROM_SEARCH, long-press shortcuts) not run (emulator owned by integrator). Real Assistant voice and the MediaController onSetMediaItems path are device-only.

## Questions for Levi
- None blocking.
