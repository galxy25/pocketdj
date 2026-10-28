state: implemented

# SVC-7 Document sync engine + ProfileStore + in-memory CloudDocDatabase + SyncRegistry

- [x] CloudDoc / CloudDocDatabase (+ UnavailableCloudDocDatabase default) / InMemoryCloudDocDatabase (failure + latency injection)
- [x] CloudSyncService verbatim port (LWW 2 s skew, .pre-cloud backup, watermark + merge-on-reload clear, meta-probed pushDirty with blind fallback, 8 s launch deadline, 5 min foreground throttle, 20 s tick, push gate, restoreForOnboarding, probeCloudProfile 10 s -> Unknown, clearLocalSyncState, StateFlow status)
- [x] ProfileStore (pocketdj-profile.json, iOS keys), SyncRegistry (registers FeatureModule.syncEntries), SyncSettings (cloudSyncEnabled, debugInMemorySyncDb)
- [x] reloadFromDisk: CollectionsStore (+performerName), PlayHistoryStore (union by id, monotone field merge, conditional save), CollectionActivityStore (union by id, inline re-save)
- [x] ServicesGraph wiring: profile, cloudSync, cloudDocDatabase seam, core syncEntries (profile, collections, play-history, collection-activity, play-stats), startCloudSync launch pipeline, ON_STOP push flushable, reset hook
- [x] Settings > Profile: name edit via ProfileStore, sync toggle, Sync now, status line
- [x] Tests: 52 new JVM tests (CloudSyncServiceTest, ProfileStoreTest, SyncRegistryTest, ReloadMergeTest); full suite 3180 tests, 0 failures; assembleDebug green

## Notes / files touched outside owned list
- MainActivity.kt: one additive line `graph.servicesGraph.startCloudSync()` (launch pipeline; AppGraph not edited).
- Default backend is UnavailableCloudDocDatabase (no account); SVC-9 assigns `servicesGraph.cloudDocDatabase`. Debug flag `debugInMemorySyncDb` swaps in the in-memory DB on debuggable builds.
- Other areas' stores (favorites, games, studio-cues, etc.) register through their own syncEntries; mix-sessions/playback-session/mix-decks/rec keys are not registered here (their owners add them).
- Account-deletion cloudDocKeys test (lockstep with registry) belongs to the package that adds AccountDeletionService.

## Questions for Levi
- None blocking. Default `cloudSyncEnabled` = true (iOS parity); with no backend configured the Profile caption reads "Sync isn't set up on this device yet."
