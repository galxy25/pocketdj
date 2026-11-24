state: implemented

# P2-MIX-2 - Mix tab Volume Glide + visible deck trims

Summary: with Settings > Mixing > Volume glide on, every Auto-DJ deck song is leveled to -14 LUFS on its TRIM (fader untouched; trim = boost + level in ParamsComposer), measured off-main through the shared LoudnessCache on load / stream completion, set at once on a silent deck and ramped 2 s (20 ms steps) on a sounding one. Stop / glide off / eject / Auto-DJ end clears it. Each deck shows "+2.1 dB" / "measuring..." / "unavailable" under Vol; a "Vol Glide" pill shows in the Mix screen while on (tap turns it off).

Tests: 26 new (MixVolumeGlideTest: rules, state machine over a fake host, composer, engine end to end incl. hand mix never leveled, crossfader sweep leaves trim alone). :app:testDebugUnitTest 6851 tests, 0 failures; :app:assembleDebug green. assembleRelease not run (no manifest/gradle/proguard/library change).

## Checklist
- [x] mix/engine/MixVolumeGlide.kt (LevelingStatus, LevelSide, DeckLeveling, VolumeGlideRules, MixVolumeGlide)
- [x] MixEngine: volumeGlide, loudnessCache seam, per-deck file/streaming bookkeeping, load/eject hooks, levelDriver + glideScope ctor params (defaulted)
- [x] UI: DeckControls LevelingReadout + VolGlidePill; hooked in DeckView / MixScreen
- [x] tests, count moved (+26)

## Touched outside owned files (minimal, additive)
- mix/graph/RenderParams.kt: DeckInputs.levelDb, ParamsComposer.setLevelDb (not a boost write)
- mix/engine/AutoDj.kt: three `engine.refreshVolumeGlide()` one-liners (start, endAutoLoop, restoreSuspended)
- mix/engine/StreamDecks.kt: engine.streamSettled on finish / truncation
- screens/mix/DeckView.kt (readout under Vol), di/MixGraph.kt (LoudnessCache at filesDir/loudness.json, setting followed by engine on Main)

## Deviations
- No quick-pass "estimated" status (iOS AudioAnalysisScheduler has no Android equivalent): a deck reads "measuring..." at 0 dB until the full measurement lands.
- A deck with no readable file reads "unavailable" instead of iOS's perpetual "measuring".
- A cancelled shared analysis is re-kicked once per load (iOS unbounded) to avoid a loop if the cache scope is dead.
- MixGraph.loudnessCache is a new app-level instance; P2-DJ-11 (DJ Mode) should reuse it so the file has one writer.

## Questions for Levi
None.
