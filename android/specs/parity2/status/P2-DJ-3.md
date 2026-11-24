state: merged

# P2-DJ-3 Progressive on-device analysis

- [x] BeatDetect.detectGridWithConfidence(pcm, maxSeconds) + GridResult (confidence = winning lag's normalized autocorrelation); detectGrid unchanged
- [x] KeyDetector.detect/chromagram take maxSeconds (strength already existed)
- [x] AudioAnalysis: quickWindow, Result (tolerant JSON), precedence (bpm/camelot/levelGain, hint clamp +-4 dB), passes via PassSource seam (MediaCodec platform impl), usableChanged
- [x] AudioAnalysisCache: analysis.json, LRU 5000 finals, hints launch-only, 1 s debounced off-main save, per-entry tolerant decode
- [x] AudioAnalysisScheduler: one pass at a time, priority CURRENT > USER_NEXT > NEXT > WINDOW, power-save/thermal SEVERE gate (deviceMayRun/powerGate), head recheck 5 s <= 24, cancelPending, onResult(key, result, usableChanged)
- [x] Tests: AudioAnalysisTest + AudioAnalysisSchedulerTest = 39 new tests; full suite 6858 run, 0 failures. assembleDebug green.

## Notes / deviations
- Engine-only; not wired to the planner/UI (P2-DJ-11 owns the wiring: construct cache with filesDir/analysis.json, scheduler with powerGate(context), call resume() on power-save/thermal change, re-plan when onResult's usableChanged is true).
- Quick/full passes decode at 22.05 kHz (detectors are rate-agnostic; cheaper than 44.1).
- availableSeconds uses the container's declared duration (MediaExtractor); a growing file whose header lacks duration reports 0 and retries up to 24 x 5 s.
- Android's smoothed-lag tempo estimator is kept; confidence is the max of the 3 neighbouring-lag autocorrelations over zero-lag energy (iOS uses the single lag).
- Lowest-level running passes are not interrupted by cancelPending (same as iOS); only the queue and head retries drop.
- No manifest/gradle/proguard changes, so assembleRelease not run. No files outside owned set touched.

## Questions for Levi
None.

## Review
- MAJOR availableSeconds = declared duration -> fixed: PassSource.availableSeconds(path, complete); for a growing file Platform uses bytes-on-disk / bitrate (KEY_BIT_RATE, fallback 128 kbps) capped by the declared duration (AudioAnalysis.estimateAvailable). quickPass also rejects a head window that decodes < MIN_HEAD_SECONDS, and the scheduler now retries the head (waitForHead) when a head pass yields nothing (previously only when no window). Tests: headPassOverASliverOfAudioIsRejected, estimateAvailableUsesBytesOverBitrateCappedByDeclared, growingFileWhoseDecodeYieldsASliverStoresNoHeadHintAndRetries.
- MINOR slice start ignored -> fixed: scheduler uses max(0, available - sliceStart). Test: sliceStartIsSubtractedFromTheSharedSidesAvailableSeconds.
- MINOR no power/thermal re-pump -> fixed: AudioAnalysisScheduler.registerGateListeners(context, scheduler) (thermal listener + ACTION_POWER_SAVE_MODE_CHANGED receiver -> resume(), returns unregister). P2-DJ-11 must call it when constructing the scheduler.
- MINOR 120 s full pass memory -> fixed: Platform.decode streams via AudioDecoder.decodeChunks into AudioAnalysis.StreamingMono (mono 22.05 kHz, linear resample, state across chunks); no native-rate accumulation. Test: streamingMonoResamplesChunkedInputLikeOneShot.
- NIT concurrent writeNow -> fixed: writes serialized under a write lock.

fixes applied. Tests: 6863 run (was 6858, +5), 0 failures; assembleDebug green.
