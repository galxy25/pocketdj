state: implemented

# P2-DJ-2 — BS.1770 loudness meter + LoudnessAnalyzer + LoudnessCache

- [x] audio/dsp/Loudness.kt: K-weighting biquads, 400 ms/100 ms-hop blocks, -70/-10 LU gates, mono-sum, LoudnessLeveling (-14, clamp -12..+6), LoudnessSegment, cancel flag
- [x] audio/core/AudioDecoder.decodeChunks (shared touchpoint, additive): streaming ranged decode, cancel polled per loop
- [x] playback/dj/LoudnessAnalyzer.kt (decoder seam for JVM tests)
- [x] playback/dj/LoudnessCache.kt: filesDir/loudness.json (caller passes the File), key songId+byteSize+segment, tolerant decode, debounced off-main save + flush(), single-flight, failure memo, cancelAll, NotReady for growing files
- [x] Tests: LoudnessTest (8), LoudnessCacheTest (10); full suite 5922 tests, 0 failures; assembleDebug green (no manifest/gradle/proguard change, so no assembleRelease)

## Notes
- Measured: 1 kHz stereo at -23 dBFS reads -23.00 LUFS at 44.1/48/96 kHz; mono reads 3.01 dB lower.
- Growing-file guard is an `isComplete: () -> Boolean` param on analyze/analyzeIfNeeded (returns Outcome.NotReady, remembers nothing); P2-DJ-11/MIX-2 supply the predicate.
- Cache takes a File? (callers pass File(filesDir,"loudness.json")); no singleton added, integrators own wiring.
- Relative-gate test tolerance 0.3 LU (blocks straddling a level step).

## Questions for Levi
None.

## Review
- MINOR single-flight race (LoudnessCache): fixed. Table write + inFlight/flags removal now in one synchronized block (storeLocked); scheduleSave outside. Test: noDuplicateDecodeWhenCallersArriveAtCompletion.
- MINOR awaiters hang if scope dies: fixed. Completion and inFlight cleanup in finally, plus job.invokeOnCompletion for a job cancelled before running. Test: tornDownScopeCompletesAwaitersAndClearsInFlight.
- NIT zero-length segment: fixed. analyzeSync returns null without decoding when lengthMs <= 0. Test: zeroLengthSegmentMeasuresNothing.

fixes applied
