state: merged

- [x] Studio row tap -> store.playNow([id]) + open Now Playing (Pocket + Playlist detail); failure -> snackbar
- [x] studioArtist = profile name, fallback "Pocket DJ" (AppGraph collections lazy; studioArtistFor())
- [x] Studio row subtitle shows the profile name (rememberStudioArtist)
- [x] Clean-only dimming: isCleanOnlyDimmed(cleanOnly, song) on pocket + playlist catalog rows
- [x] PlaylistDetail/PocketDetail silent null return from playNow -> "Catalog isn't ready yet" snackbar
- [x] Tests: 3 new in RealizeStudioEntriesTest (15 total in class); suite 5599, 0 failures

Notes: ANS-PB-1 had no status file in this branch, so dimming uses EditionPolicy.isSkipped directly (same predicate the sequencer stamps cleanOnlySkip with). assembleRelease not run (no manifest/proguard/build changes).

## Questions for Levi
None.

## Review
- MINOR PocketDetail/PlaylistDetail studio row tap ignored repeat count -> fixed (repeats, sourceToken, originId passed to store.playNow in both screens; test playNowHonorsRepeatCountForASingleStudioRow)
- MINOR artist-from-profile wiring untested -> fixed (wireStudioArtist(store, profile) in CollectionCatalog.kt, called by AppGraph; test against a real ProfileStore on a temp file)
- NIT rememberStudioArtist per-row collector / main-thread profile read -> not changed (optional; one-frame default only)

fixes applied. Suite 5601, 0 failures (was 5599; +2). assembleDebug OK. (MicRecorderLifecycleTest stall watchdog flaked once, passed on rerun, unrelated.)
