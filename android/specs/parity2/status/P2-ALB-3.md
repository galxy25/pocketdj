state: implemented

# P2-ALB-3 — shared-file start readers via SegmentOverrides + lone vinyl song end on the record

- [x] `AnalogWindow.endMs/lengthMs` (+ `Run`) pure helper
- [x] `RipsRepository.analogEndMs` (timeline + overrides); `PlayResolver.resolve/resolveBurnedFirst` take `endOf`; `ManifestRowResolver(endOf)`; PlaybackController wired (3 sites)
- [x] MixStreamLoader reads `effectiveStartMs` (new default method on `MixStreamRips`, MixGraph implements)
- [x] NP DSP `windowLengthMs` (MixGraph) = end on the record - start
- [x] MixWaveform / MixScreen / CuesScreen / CueSeek read effective start + end
- [x] Already satisfied by ALB-1: BurnStore.startMs (override), burned `endMs` (ServicesGraph), StudioGraph readers (all via `burns.startMs`).

Tests: 13 new in AnalogWindowTest; full suite green (see commit), :app:assembleDebug green. No manifest/gradle/proguard touched (no assembleRelease needed).

## Deviations / files touched outside owned list (minimal, additive)
- data/rips/PlayResolver.kt, RipsRepository.kt, playback/sequencer/RowSourceResolver.kt, screens/mix/MixScreen.kt, di/MixGraph.kt, PlaybackController.kt.
- `run` (album run) is a parameter only; P2-ALB-4 supplies it. `isUnboundedAnalog` queue truncation left in place (ALB-4/5 removes it).
- Studio demux/LocalAudioCache already use `burns.startMs`; their song-length values left as catalog length (iOS parity).

## Questions for Levi
None.
