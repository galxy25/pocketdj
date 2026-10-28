state: implemented

# BRW-13 Cloud recommendation engine service + client + rec key + Settings + Suggested collections

JVM tests: 4224 total, 0 failures (+57 new: RecEngineClientTest 15, RecommendationServiceTest 42). assembleDebug green.

## Checklist
- [x] RecModels.kt (wire types, lenient decoders, RecSuggestionFilter, RecCollectionFlattener w/ caps)
- [x] RecEngineClient.kt (headers per route, enroll only on POST /events + DELETE /state, 403 mapping, per-route timeouts)
- [x] RecommendationService.kt (gate, key mint, HMAC scoped id, 30-day window cursors + newest-kept acks (25k), batches 500, snapshot caps + 3.5MB guard + 413 fallback, play-counts hash gate, audio shortlist, epoch abandon, cloudZoneRanking, forYou TTL, suggestions LRU 20, similar LRU 8, deleteCloudData, tombstone retry, scoped-id migration, auto-flush one-loop)
- [x] RecsSettings.kt (recEngineEnabled default off, shareLifetimePlayCounts default on) + REC_ENGINE_ENROLL_SECRET in Endpoints.kt
- [x] RecommendationsSection (order 660) registered in BrowseGraph.settingsSections
- [x] SongDetailSheet "Suggested collections" block (Add / Added, top 5, unresolved dropped)
- [x] BrowseGraph: recService lazy, startRecs() launch hook, flushable (flushSoon on ON_STOP), sync entry "rec-key", reset hook (deleteCloudData then clearLocal)

## Files touched outside owned list (minimal, additive)
- di/AppGraph.kt: one `init { browseGraph.startRecs() }` (arms the auto-flush loop at launch; D3 has no launch hook)
- data/reset/AccountDeletionService.kt: added "rec-key" to cloudDocKeys (lockstep test demanded it so the cloud copy dies on account deletion)
- test data/reset/AccountDeletionTest.kt: registry set gained REC_KEY_SYNC_KEY

## Deviations / notes
- ForYouGate.REC_ENGINE_ENABLED (BRW-11) already declares the same persisted key name "recEngineEnabled"; RecsSettings re-declares it (same name, so one DataStore value).
- iOS UI/test fixture mode (PDJ_REC_FIXTURE) not ported.
- "Find my listening pockets" toggle + places/trips are COL-17/18 / COL-20; not in this section. Delete cascade seam `onDeleteCloudData` is exposed for them.
- Gem Collector wiring of similarSongs(), RecFeedbackStore -> feedbackProvider is wired; puzzleEventsProvider left null (Games wires it).
- Pending-delete tombstone file: pocketdj-rec-pending-delete.json (device-local, never synced).
- Not run on emulator (per instructions); emulator steps in roadmap remain for integrator.

## Questions for Levi
- None blocking. Enrollment secret is mirrored verbatim from iOS Config.swift (same as the .ipa); confirm that is acceptable for the APK too.
