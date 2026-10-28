state: implemented

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
