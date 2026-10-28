state: merged

# BRW-17 - '?♪?' recognizer + Apple Music actions

- [x] ShazamCatalogMatch (norm/resolve, ShazamHitInfo/ShazamMatch)
- [x] AppleMusicRecognition (action reducer, indexAlbum/indexSong/burnSongId, Web-API parsers, port)
- [x] ShazamRecognizer (phase state machine, mic gate, mix-recording gate, second-tap cancel)
- [x] ShazamButton (top of Browse), ShazamResultSheet, AppleMusicRecognitionSection
- [x] BrowseGraph: shazamBackend + appleMusicRecognition port (Web API + rip server)
- [x] Tests: 3 files (ShazamCatalogMatchTest incl. ShazamRecognizerTest, RecognitionActionReducerTest); full suite 4899 tests, 0 failures; assembleDebug green

## Deviations / notes
- The ShazamKit-for-Android AAR is not in the repo (Apple developer-portal download), so `app/libs/shazamkit-android.aar` and the
  build.gradle.kts dependency are NOT added. The default backend is `UnavailableRecognitionBackend` (button reports failed).
  The AudioRecord + StreamingSession adapter plugs into `BrowseGraph.shazamBackend` once the AAR is vendored. DEVICE-ONLY.
- Touched outside owned files (additive): `data/applemusic/AppleMusicApi.kt` (recognizedSong, recognizedSongSearch, librarySongsContain).
- Edition-preference swap before add (VariantResolver) not ported; the recognized store id is used as-is.
- openRecognizedAlbum (library hit, album not in index) opens the album URL in the Apple Music app (no synthesized album page on Android).
- Result sheet "Open song" closes the sheet and opens Browse's SongDetailSheet.

## Questions for Levi
- Can you supply shazamkit-android.aar (+ developer token setup) so the live backend can be wired?

## Review
- MAJOR BrowseGraph add never burns -> fixed: port.startRipAndBurn registers BurnStore.burnWhenRipped first, drains immediately when already ripped / requestRip isReady (manifest refreshed), else tracker onRipReady drains. "Saved to device" now driven by BurnStore item READY, not the rips manifest; ready-but-unburned no longer spins forever. Tests: RecognitionAddControllerTest.
- MAJOR Denied never recovers -> fixed: tap() re-checks MicPermission.isGrantedNow() before OPEN_SETTINGS; ON_RESUME observer clears Denied. Test: deniedThenGrantedInSettingsRecoversOnTap.
- MAJOR backend unavailable still prompts for mic -> fixed: RecognitionBackend.isAvailable; recognizer fails before the permission prompt; Browse hides the button while unavailable. Package stays PARTIAL (AAR still not vendored). Test: unavailableBackendFailsBeforeAskingForTheMic.
- MINOR add/rip tied to sheet scope + swallowed errors -> fixed: app-scoped RecognitionAddController (BrowseGraph.recognitionAdds) with per-song add/burn error state; no-server and request failures shown under "Added".
- MINOR linked flash / Connect errors silent -> fixed: linked is nullable (Checking until known); errorText rendered in Connect branch.
- MINOR row on Discover / right-aligned -> fixed: gated `!discover && !online`, centered.
- MINOR ShakeIfDenied -> fixed (one-shot Animatable shake on Denied). Per-phase glyph animations remain unported (cosmetic).
- MINOR AppleMusicApi layering / hard-coded 'us' -> fixed: DTOs + parsers moved to data/applemusic/AppleMusicRecognitionModels.kt (norm-based library matching stays in screens via libraryRowsContain); port resolves the user's storefront once via userStorefront() (cached, falls back to us).
- NIT test file split -> fixed: ShazamRecognizerTest.kt separate.

Tests: 4899 -> 4908 (0 failures); assembleDebug green.

fixes applied
