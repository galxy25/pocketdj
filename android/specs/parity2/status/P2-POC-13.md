state: implemented

# P2-POC-13 — Listening-pockets upload Phase 6
- [x] ListeningPocketsUploadResponse.caps parsed
- [x] SyncDoc.serverCaps persisted (noteServerCaps), serverSupportsWheel
- [x] Event.mode (sensor-only, motion opt-in gated) / Event.run (RunWire) ABSENT unless serverSupportsWheel
- [x] Fingerprint suffixes |m:<mode> |r:<id>/<slot> only when present
- [x] e.pocketRun?.rowCollectionId now feeds context (POC-1 TODO resolved)
- [x] ListeningPocketsPhase6Test: 13 tests; full suite green + assembleDebug

## Deviations / notes
- New seam `ListeningPocketsService.motionOptedIn` (default off). NOT wired in app code (outside owned files): whoever owns the "Notice walking & running" setting must set `motionOptedIn = { settings.noticeMotion }` where `locationOptedIn` is wired. Until then mode is never sent.
- serverCaps is preserved across a profile rebind reset (server capability is not per-profile).
- Touched test/PocketsTestSupport.kt additively (`eventsBody` knob on the fake backend).
- one-at-a-time.sh refused with --no-quiesce-fin (LM Studio model resident); ran with default quiesce.
- assembleRelease not run (no manifest/gradle/proguard/library changes).

## Questions for Levi
None.
