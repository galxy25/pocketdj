state: implemented

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
