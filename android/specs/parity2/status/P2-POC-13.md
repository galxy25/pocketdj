state: merged

# P2-POC-13 — Listening-pockets upload Phase 6
- [x] ListeningPocketsUploadResponse.caps parsed
- [x] SyncDoc.serverCaps persisted (noteServerCaps), serverSupportsWheel
- [x] Event.mode (sensor-only, motion opt-in gated) / Event.run (RunWire) ABSENT unless serverSupportsWheel
- [x] Fingerprint suffixes |m:<mode> |r:<id>/<slot> only when present
- [x] e.pocketRun?.rowCollectionId now feeds context (POC-1 TODO resolved)
- [x] ListeningPocketsPhase6Test: 12 tests; full suite green + assembleDebug

## Deviations / notes
- New seam `ListeningPocketsService.motionOptedIn` (default off). NOT wired in app code (outside owned files): whoever owns the "Notice walking & running" setting must set `motionOptedIn = { settings.noticeMotion }` where `locationOptedIn` is wired. Until then mode is never sent.
- serverCaps is preserved across a profile rebind reset (server capability is not per-profile).
- Touched test/PocketsTestSupport.kt additively (`eventsBody` knob on the fake backend).
- one-at-a-time.sh refused with --no-quiesce-fin (LM Studio model resident); ran with default quiesce.
- assembleRelease not run (no manifest/gradle/proguard/library changes).

## Questions for Levi
None.

## Review
- MINOR motionOptedIn never wired -> fixed: CollectionsGraph sets `svc.motionOptedIn = { app.pocketsGraph.motionStore.isActive }` (opt-in AND permission), next to the other svc seams. Existing Phase6 tests cover the gate via the seam.
- NIT serverCaps kept across profile rebind -> rejected (server capability is not per-profile; deliberate deviation, first response corrects caps).

fixes applied

Final: full suite 7468 tests, 0 failures; assembleDebug green at tip. Phase6 test: 12 tests.
