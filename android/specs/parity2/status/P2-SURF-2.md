state: implemented

- [x] MediaButtonPrefs (pure specs + CommandButton mapping, trusted pdj.shuffle/repeat/rec.accept/rec.reject commands)
- [x] PlaybackService: setMediaButtonPreferences replaces setCustomLayout; commands added in onConnect; handlers in onCustomCommand; rebuilt via RunTransportBus.stateChanged (main-thread hop)
- [x] Tests: MediaButtonPrefsTest (9 tests); full suite 6657 tests, 0 failures; assembleDebug green

## Summary
Button set: heart (exo owner only), shuffle + repeat (effective mode) only while a run is live, thumbs pair only with a rec target (lit = standing verdict, tap on lit clears via NowPlayingFeedback.record; never touches transport). Surface = CAR_PLAY for Android Auto packages, else NOW_PLAYING.

## Deviations / touched outside owned files
- RunTransportBus.kt not edited. NowPlayingFeedback.record now invokes RunTransportBus.stateChanged after a verdict (so verdicts from any surface rebuild the buttons). BrowseGraph gained additive nowPlayingFeedbackIfReady() (null until rec stores are built; never forces a load from the service).
- FavoriteCommand.kt unchanged (its button()/visible()/filled() reused). assembleRelease not run (no manifest/gradle/proguard/library change).
- Repeat tap in a pocket run is inert because the sequencer refuses the change (glyph stays off).

## Questions for Levi
None.
