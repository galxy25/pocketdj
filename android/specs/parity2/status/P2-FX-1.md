state: implemented

# P2-FX-1: FX Lock

- [x] FxLock.kt: FxLockState / FxLockSession (SessionExtra `fxLock`, iOS JSON via SessionFxLock DTO, unknown effect keys kept), indicator rule, ramp constants
- [x] Engine: onUserEffectChange (user only), effectSettings, applyCarriedEffects (0.25 s ramp from transparent, user touch beats it), engage-time ramp of stamped effects
- [x] Host: stamp carry on idle DSP, engage at start on every mixable start path (carryIfReady, swap-on-land/hand-off, growing start via engage ramp), WAITING/DORMANT, refused file stays on ExoPlayer, session scope, setFxLock
- [x] Capsule `np-mix-fx-lock` in the Effects header (upper right), no status line
- [x] Lane: replanStemLock plans with fxLockSongs while the lock carries effects (no stems)
- [x] Tests: FxLockTest, 25 tests, all green. Full suite 6673 tests, 0 failures; :app:assembleDebug green.

## Files outside the owned list (minimal, additive)
- di/MixGraph.kt: fxLockSession (debounced persist), host ctor arg, register as session extra, lane replan (fxLockSongs, FX wants), held-restore stamp.
- screens/nowplaying/NowPlayingDspPanel.kt (shared touchpoint): Effects header row with the capsule.
- NowPlayingPrefetcher.kt already had fxLockSongs; unchanged.

## Deviations
- wantsFX counts only effects this build knows (iOS counts any `on`); an unknown ON effect could not be applied, so it should not engage the DSP.
- Dead-air "exactly one transition" relies on the existing sequencer first-audio path (engage reuses the Stem Lock engage); no separate JVM test with the meter; to confirm on the emulator.
- assembleRelease not run (no manifest/gradle/proguard/library change).

## Questions for Levi
- None.
