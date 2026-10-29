state: reviewed

# ANS-STU-2 Tracks paging part A: streaming master bake + bounce

- [x] StreamingResampler (audio/core) + test
- [x] AacEncoder.Stream (streaming MediaCodec, PcmChunkWriter); encode() delegates
- [x] StudioCodec.openM4a (+BufferedM4aWriter fallback); AndroidStudioCodec streams
- [x] MasterWav.readChunks/header; MasterRecordingBaker streams (resample -> encoder)
- [x] ArrangerBouncer: block-wise render, 2-pass peak scan, streams to encoder
- [x] Full test run: 5224 tests, 0 failures (13 new); assembleDebug green. Unrelated flaky ReleaseFeedServiceTest failed once, passed on rerun.

## Notes / deviations
- Touched outside owned files (minimal, additive): studio/engine/MultitrackRenderContext.kt gained `renderOfflineBlocks`; `renderOffline` now delegates to it.
- Constructors: `MasterRecordingBaker`/`ArrangerBouncer` keep the `writeM4a` seam (nullable now; buffered fallback) and add `openM4a`.
- Bounce render block is 4096 frames (was 512); chunk-invariance is covered by the existing live==bounce test.
- Still held in memory: ArrangerClipPlan clip windows (paging part B's concern).
- MediaCodec streaming itself (AacEncoder.Stream) is NOT JVM-testable and has NOT been run on a device/emulator: UNVERIFIED. JVM tests use fake PcmChunkWriters only.

## Questions for Levi
- none

## Review

fixes applied (5225 tests, 0 failures; assembleDebug green; +1 test)

- MAJOR emulator step not run / status overstated -> PARTIALLY fixed: status file corrected (MediaCodec path marked UNVERIFIED). Emulator run rejected for this pass (task forbids using the shared emulator); INTEGRATOR TODO before ledger update for STU-11/STU-13: record 5 min master, bake, confirm .m4a plays with right duration, compare dumpsys meminfo, bounce an arrangement and play it.
- MINOR keep-capture on read failure -> fixed: bakeArtifact keeps the capture on any non-encoder failure (read/header-null mid-stream); encoder/rename faults still delete. Test: midReadFailureKeepsTheCaptureAndClosesTheOpenWriter.
- MINOR writer leaked on `?: return null` -> fixed: now throws into the catch path that aborts/closes the writer (test above asserts writer released).
- MINOR heap criterion only indirect -> partially fixed: ten-minute test fake now creates the tmp file so the success/artifact path is exercised. A real -Xmx bound not added (rejected: block-size assertion on the sink plus StreamingResampler OUT_FRAMES bound is the practical guard).
- NIT 2-pass bounce cost -> rejected, acceptable as designed.
- NIT MultitrackRenderContext shared touchpoint -> flagged to integrator: additive `renderOfflineBlocks`; `renderOffline` delegates to it.
