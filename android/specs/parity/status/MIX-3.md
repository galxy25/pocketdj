state: implemented

# MIX-3 Shared DSP nodes (audio/dsp)

- [x] DspNode interface (interleaved stereo float, in place, bypass bit-identical) + Biquad (RBJ, TDF2)
- [x] Eq3 (320 Hz low shelf / 1 kHz peak / 3.2 kHz high shelf, +/-12 dB, 0 dB band skipped = transparent), TrimGain (dB, 5 ms glide)
- [x] TimePitch (SonicAudioProcessor wrapper, push/pull, s16<->float, drain-before-reconfigure so live speed/pitch changes keep the tail, flush() on seek)
- [x] Compressor, Limiter (lookahead min-filter + box average + hard clamp), Reverb (Freeverb, 4 presets), ModDelay
- [x] Meter + MixDeckLevels, EnvelopeFollower (32-frame RMS chunks, 8/180 ms, block-size independent), FxSlotNodes (applySlot/writeSlotParams)
- [x] Tests: 53 new JVM tests (Biquad 10, TimePitch 8, Limiter 5, Meter+Envelope 9, FxSlotNodes 9, Dynamics 6, ReverbDelay 7); full suite 679 tests, 0 failures (626 before)

## Notes / deviations
- Package is `audio/dsp` (roadmap), not audit's `mix/dsp`. Added helper test file DspTestSupport.kt and extra test files DynamicsTest/ReverbDelayTest (roadmap unit_tests names).
- Buffer convention: interleaved stereo FloatArray, `frames` count. TimePitch is push/pull (output count differs from input).
- LP/HP filter resonance uses fixed Q=1.0 (AU bandwidth semantics don't map to a sane Q); BP uses bandwidth->Q.
- Compressor ratio derived from headroom (20/headroom clamped 2..20); not a bit-match to Apple's DynamicsProcessor.
- Reverb "rebuild" = loadPreset (retune + clear tail), counted by presetLoads.
- Device-only: subjective quality of Sonic at large stretch ratios, reverb/compressor voicing vs. Apple units.
- No files touched outside owned set. docs/ARCHITECTURE-ANDROID.md untouched per instructions.
