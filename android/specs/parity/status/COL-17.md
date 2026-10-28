state: merged

# COL-17 - ListeningPocketsService + PocketsPlayListener + real PocketsBridge

- [x] PlayEvent: added `listeningContext` + `carPlay` (wasSkipped/listenedFraction/tzOffsetMin/originInstallId + MAX-merge + derived outcome already existed; thresholds verified against iOS PlayHistoryStore.swift: skipped > fraction>=0.5 completed > partial > unknown)
- [x] PlayHistoryStore: `carPlayProbe`, `stampContexts` (write-once, local-only)  [outside owned files, additive]
- [x] data/location/ListeningContext.kt (lookup/provider contract + Noop)
- [x] PocketsSettings.kt (LISTENING_POCKETS_ENABLED, LISTENING_LOCATION_ENABLED, consent text)
- [x] ListeningPocketsService (gate, fingerprint diff, 90d window, batch 1000, sent-on-2xx, profile rebind reset, epoch abandon, isDeleting/uploadFloor, collections snapshot, nullable rounds seam, results TTL+cache, 404 silent, debounce 5s / auto 25s+600s, onDisabled)
- [x] PocketsPlayListener (carPlay probe, background flush), LivePocketsBridge (GM-7 contract)
- [x] CollectionsGraph wiring (servicesBridge, pocketsOptIn, recService.onDeleteCloudData cascade, ON_STOP flush)
- [x] Tests: ListeningPocketsServiceTest (14), LivePocketsBridgeTest (4), PocketsPlayListenerTest (3), PlayHistoryOutcomeTest (4) = 25 new; full suite 4981 tests, 0 failures

## Notes / deviations
- Files outside the owned set touched (additive): data/history/PlayHistoryModels.kt, data/history/PlayHistoryStore.kt; a shared test helper data/pockets/PocketsTestSupport.kt (test dir); PlayHistoryOutcomeTest lives in test/.../data/history.
- No location engine on Android: provider is Noop, so ctx is never stamped; `onDisabled` flips LISTENING_LOCATION_ENABLED off (pref only).
- carPlay probe = UiModeManager UI_MODE_TYPE_CAR (Android Auto on a phone is not detectable without the car-app library).
- Rounds upload reuses GamesGraph.roundsClient (own ack file); delete cascade tells it the floor via setUploadFloor. `clearLocal()` exists but is not yet hooked into AccountDeletionService (not my file).
- Account-deletion `clearLocal` hookup and the Settings toggle UI for LISTENING_POCKETS_ENABLED are not in this package.
- Not exercised on emulator (forbidden); MockWebServer JVM tests cover the flow.

## Questions for Levi
None.

## Review
fixes applied
- MINOR cold-start gate flip (CollectionsGraph) -> fixed: mirror seeded from stored pref via first() before the first evaluation; single combine+distinctUntilChanged collector; service tracks lastGate so onDisabled fires only on a real true->false change; flushEpoch is now an AtomicInteger. Test: coldStartDoesNotFireOnDisabledAndRealCloseFiresOnce.
- MINOR flush/delete race (ListeningPocketsService) -> fixed: isDeleting check, epoch read and flushDone registration share flushLock in flushNow; deleteCloudData sets isDeleting, bumps epoch and reads flushDone under the same lock. Test: deleteWaitsForFlushThatRegisteredBeforeIt.
- MINOR PlayHistoryStore merge -> fixed: first-writer-wins absorption of listeningContext and carPlay, plus holdsFieldsMissing for both. Tests: reloadAbsorbsPeerContextAndCarPlayFirstWriterWins, reloadSavesWhenWeHoldContextOrCarPlayTheDocLacks.
- MINOR clearLocal unhooked -> fixed: "listening-pockets" local store in ServicesGraph.accountDeletion calls listeningPockets.clearLocal().
- NIT ledger row / emulator step -> not done: docs/ARCHITECTURE-ANDROID.md owned by orchestrator; emulator forbidden here (integrator owns it), so device-only: MockWebServer POST after 25 s.

Verification: 4985 tests (was 4981, +4), 0 failures; assembleDebug OK.
