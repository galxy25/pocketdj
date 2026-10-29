state: in-progress

# ANS-STU-2 Tracks paging part A: streaming master bake + bounce

- [x] StreamingResampler (audio/core) + test
- [x] AacEncoder.Stream (streaming MediaCodec, PcmChunkWriter); encode() delegates
- [x] StudioCodec.openM4a (+BufferedM4aWriter fallback); AndroidStudioCodec streams
- [x] MasterWav.readChunks/header; MasterRecordingBaker streams (resample -> encoder)
- [x] ArrangerBouncer: block-wise render, 2-pass peak scan, streams to encoder
- [ ] Full test run + count

## Notes / deviations
- Touched outside owned files (minimal, additive): studio/engine/MultitrackRenderContext.kt gained `renderOfflineBlocks`; `renderOffline` now delegates to it.
- Constructors: `MasterRecordingBaker`/`ArrangerBouncer` keep the `writeM4a` seam (nullable now; buffered fallback) and add `openM4a`.
- Bounce render block is 4096 frames (was 512); chunk-invariance is covered by the existing live==bounce test.
- Still held in memory: ArrangerClipPlan clip windows (paging part B's concern).
- MediaCodec streaming itself is not JVM-testable; covered by emulator step.

## Questions for Levi
- none
