state: reviewed

# GM-8 In the Pocket screen + on-device feedback dictation

- [x] FeedbackDictation.kt (controller + fake-able engine seam + SystemFeedbackSpeechEngine, on-device only)
- [x] PocketsOptInView.kt (+ PocketsOptIn seam)
- [x] InThePocketComponents.kt (InThePocketScreenLogic, stats, dots, song rows)
- [x] InThePocketScreen.kt
- [x] GamesGraph.pocketsOptIn; GamesRoutes wiring
- [x] InThePocketScreenLogicTest (screen logic + FeedbackDictationTests port)

## Deviations / files outside owned set
- screens/games/GamesRoutes.kt: additive `showInThePocket` push (onOpenInThePocket default now opens the screen).
- Android has no rec-engine / listening-pockets Settings yet: `PocketsOptIn` seam in PocketsOptInView.kt; GamesGraph default
  only flips the debug `pdj.pocketsStub` gate. The services wave must assign `gamesGraph.pocketsOptIn` (and servicesBridge).
- Dictation uses SpeechRecognizer.createOnDeviceSpeechRecognizer + isOnDeviceRecognitionAvailable; no cloud fallback.
- Strings use ASCII hyphen instead of em dash in a few copy lines.

## Questions for Levi
- Consent copy in PocketsOptInCopy.CONSENT is a placeholder paraphrase of ListeningPocketsService.consentText; services wave should swap in the canonical text.

## Result
14 new tests (InThePocketScreenLogicTest); full suite 3695 tests, 0 failures; assembleDebug green. Build needed -Pkotlin.daemon.jvmargs=-Xmx3g (shared-machine OOM).
Device-only: real SpeechRecognizer dictation.

## Review
fixes applied (suite 3702 tests, 0 failures; +7 in GM8ReviewFixesTest; assembleDebug green)
- MAJOR consent text -> fixed: PocketsOptInCopy.CONSENT is now verbatim ListeningPocketsService.consentText; test compares against the iOS source and checks every disclosed item. "Questions for Levi" item resolved.
- MINOR release tile dead-end -> fixed: NoPocketsBridge now shows "In the Pocket isn't available." (iOS third branch).
- MINOR recs note unreachable in debug -> fixed: recommendationsEnabled is a StateFlow; debug extra `pdj.pocketsRecsOff` flips it; showNeedsRecs logic tested.
- MINOR mic busy -> fixed: start() refuses while AudioFocusPolicy.micCaptureActive; deliberately does NOT call beginMicCapture (it would block playback via mayStartPlayback) - asymmetry vs iOS.
- MINOR locale pack -> fixed: checkRecognitionSupport cached per locale; ERROR_LANGUAGE_UNAVAILABLE/NOT_SUPPORTED map to Unavailable (tested).
- MINOR single-utterance / audio focus -> partly fixed: silence windows widened to 6 s. Audio-focus ducking of round playback is device-only (verify on a device).
- MINOR double-tap while Requesting -> fixed: toggle() returns early, mic disabled while Requesting, prior `pending` completed before replacement (tested).
- MINOR ledger row -> deferred to orchestrator: docs/ARCHITECTURE-ANDROID.md GM-8 row (line ~496) to be set at integration; device-only: real SpeechRecognizer dictation + focus behaviour.
- NIT: half-filled PLAYING dot drawn; em dashes / en dash restored in the copy.
