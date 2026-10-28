state: merged

# MIX-13 Deck UI: DeckView + controls, seek slider, FX chips, stem pads, VU, loop, cue, beat pulse, waveform, crossfader, master transport

- [x] DeckControls.kt: DeckColors, DeckControlMath (pure formatting/knob/stepper/VU/seek/loop math), StepButton, DeckSlider, MixKnob, DeckPopover, ChipStrengthPopover
- [x] DeckSeekSlider.kt: gesture-scoped drag fraction cleared in `finally`, 10 Hz poll in its own composable
- [x] FxSlotChip.kt: tap toggle, long-press reveal (effect menu, MOD placeholder, variety menu, strength + steppers)
- [x] StemPad.kt, LoopChip.kt, CueButton.kt, DeckVuMeter.kt (20 Hz), BeatPulse.kt (60 fps, BeatPulsePhase pure), MixWaveform.kt (WaveformExtractor over PcmSource), CrossfaderView.kt, MixBufferingBadge.kt, CuePointsProvider.kt
- [x] DeckView.kt (DeckHost bundle + deck), DeckArea.kt (side-by-side / stacked / single, landscape override, MasterTransport `mix-play`)
- [x] Tests: DeckControlMathTest (28), BeatPulsePhaseTest (9), WaveformExtractorTest (4)

## Notes / deviations
- No file outside the owned set was touched. Nothing is routed yet: MIX-14 builds a `DeckHost(engine, stems, loops, streams, cues = StudioCuePoints{studioStore}, isStemmed, peaksFor = MixWaveform.peaksForSong, art = AlbumArt)` and calls `DeckArea` + `CrossfaderView` + `MasterTransport`.
- Source menu (crate picker) and the loader sheet are MIX-14's: DeckArea/DeckView take a `sourceMenu` slot and an `onLoad` callback.
- Beat pulse is a parameter (`beatPulseEnabled`), not read from settings (MixSettings is MIX-14); when false BeatPulse is never composed.
- MOD chip is an inert, dimmed placeholder until MIX-17 passes `DeckHost.onMod`.
- Popovers are Compose `Popup`s (focusable, outside-tap dismiss, 3 s idle timer except the FX reveal which hosts menus). Right-click is not separately handled (touch only).
- Android has no Theme object; `DeckColors` mirrors iOS Theme hex values.
- Test names: roadmap's DeckFormattingTest is covered inside DeckControlMathTest. WaveformExtractorTest added.
- JVM suite: 2800 tests, 0 failures (+41 from this package); assembleDebug green.
- Not done: emulator step (no emulator per instructions); ledger row in docs/ARCHITECTURE-ANDROID.md (integrator).

## Device-only
None per roadmap; emulator pass (drag every slider, rotate) is pending the integrator because the screen is not routed until MIX-14.

## Questions for Levi
- None.

## Review
fixes applied

- MAJOR Stems chip state: fixed (DeckControlMath.stemChipOn mirrors StemController.modeOn from the collected handovers; toggle uses it; test stemChipFollowsPendingHandover)
- MINOR seek flicker: fixed (position/duration re-read after seek and in finally)
- MINOR BeatPulse idle frames: fixed (frame loop keyed on isPlaying)
- MINOR compact rule: fixed (DeckLayoutRules.compactControls(landscape, widthDp) is the rule DeckArea runs; test updated)
- MINOR a11y adjust: fixed (MixKnob Increase/Decrease and seek Forward/Back custom actions via knobAdjust/seekStep)
- MINOR waveform cancellation: fixed (fold takes a per-chunk check; peaks passes ensureActive and rethrows CancellationException; test)
- MINOR cue row staleness: fixed (CuePointsProvider.changes flow, StudioCuePoints maps StudioStore.state)
- MINOR open acceptance: ledger row updated to PARTIAL; emulator pass carried over to MIX-14 acceptance
- NIT cue rounding: fixed (roundToInt); NIT Stems label kept while loading, unused import removed
- JVM suite: 2803 tests, 0 failures (+3); assembleDebug green.
