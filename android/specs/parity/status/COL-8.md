state: merged

COL-8 Apple Music write-back queue (Web API transport) + Apple Music settings.
- [x] WriteBackMatcher (matchKey/bestMatch, conservative + deterministic) - WriteBackMatcherTest (12)
- [x] AppleMusicLibraryPlaylists: transport seam + WebApiPlaylistWriteBackTransport over SVC-15 AppleMusicApi (tiered name resolve, overlap arbitration, membership pre-check before every append, 404 semantics) - AppleMusicLibraryPlaylistsTest
- [x] PlaylistWriteBack durable queue (iOS-shape pocketdj-playlist-writeback.json, lenient decode, persisted after every job, dedup, 4 attempts -> failed, 200 prune, cancelPending, unresolvable supersede, playlistGone re-resolve once) - PlaylistWriteBackQueueTest (24)
- [x] CollectionsStore seams: enqueue/batch/canWriteBackUpstream/cancelPending, WriteBackAttempt, per-add pocket+playlist, >50 confirm gate (StateFlow), forceWriteBackSong, backfillSourceWriteBacks, source-row path - WriteBackSourceSyncTest, WriteBackBackfillTest
- [x] WriteBackSettings (backfill days pref, clamp 1..90, status/force copy)
- [x] UI: Settings > "Apple Music playlists" section (look-back, Send my adds, Get from Apple Music, queue/failed/warning/retry); WriteBackConfirmDialog; "Force Apple Music sync" in the pocket song-row menu
- [x] CollectionsGraph wiring (lazy queue, seams, drain on launch)

Notes / deviations
- Transport is Web-API only (Android has no MusicKit); canWrite = Music-User-Token present. Signed-out adds still enqueue and wait (iOS parity); the confirm dialog is gated on transport capability, not sign-in.
- No timer/WorkManager: the queue drains on launch, on enqueue, and from Settings ("Send now"/"Retry failed"); backed-off jobs wait for the next trigger (same as iOS).
- Force sync menu is on the Pocket detail only; PlaylistDetailScreen is not owned by COL-8 (not touched).
- Touched outside owned files (minimal, additive): di/AppGraph.kt (one line: collectionsGraph.wireWriteBack(store)), shell/ShellNavigation.kt (mount WriteBackConfirmDialog), screens/collections/AddToCollectionSheet.kt (source-row copy now reports the queued write-back), test CollectionsActivityChokePointsTest (writeBackEligible assertion was the old "always false").
- Test suite: 3458 tests, 0 failures; assembleDebug green. Emulator steps not run (shared emulator).

## Questions for Levi
- None blocking. Should a signed-out Android user's adds queue at all (current: yes, iOS parity), or should enqueue wait for Apple Music sign-in?

## Review

fixes applied

- MAJOR queue only re-armed at process start -> fixed: `WriteBackForegroundDrain` ProcessLifecycleOwner ON_START observer (CollectionsGraph) + `MusicKitAuth.onSignedIn` hook calls `runSoon()`; test WriteBackForegroundDrainTest.
- MINOR unlocked `publish` RMW -> fixed: every `_state` mutation (publish, commit, clear, reloadFromDisk) uses CAS `update {}`.
- MINOR source-row `!present` -> fixed: enqueue whenever eligible and not upstream; `writeBackDeduped` / `writeBackNoIdentity` surfaced in `sourceAddMessage`; tests in WriteBackSourceSyncTest.
- MINOR Force sync only on AM-linked pocket rows -> fixed: shown on every catalog row of pockets and added to PlaylistDetailScreen song rows (NOT_LINKED now reachable).
- MINOR backfill on main thread -> fixed: runs on Dispatchers.IO and uses the batch seam (one write, one runSoon); per-item fallback kept.
- NIT unsyncableMemo -> fixed (@Volatile).
- NIT matchKey code points / marks -> fixed (code points; letters, digits, M*); WriteBackMatchKeyUnicodeTest.
- NIT status/housekeeping -> noted for orchestrator: WriteBackBackfillTest lives in data/collections; ARCHITECTURE-ANDROID.md ledger row left to orchestrator; shared-file edits (AppGraph, ShellNavigation, AddToCollectionSheet, CollectionsActivityChokePointsTest, now also PlaylistDetailScreen, PocketDetailScreen, MusicKitAuth) are merge-sequencing points.

Build: testDebugUnitTest + assembleDebug green, 3463 tests, 0 failures.
