state: merged

# MIX-2 Shared audio core (audio/core)

- [x] FloatRing (SPSC), RenderClock, AudioSink + BlockRenderer, OfflineRenderer
- [x] PcmSource, ConvertedSource (mono upmix + linear resample fallback), SyntheticPcmSource, PcmBuffer
- [x] Mp3FrameReader (ID3v2 skip, Xing/Info/VBRI, LAME delay/padding, 576 untagged priming, 529 decoder delay, playableFrames, frame<->sample map)
- [x] Mp3Decoder (MediaCodec sync), AudioDecoder (MediaExtractor -> canonical 44.1k stereo float), WavWriter (+Streaming), AacEncoder (m4a + ADTS)
- [x] Voice (3-step schedule handshake, loop in decoder + position counter, scheduled start, gain ramp, underrun hold, ended) + VoicePump, VoiceGroup, AudioDiag
- [x] AudioTrackSink (float, low-latency, urgent-audio thread, device-callback recreate, underrun count)
- [x] JVM tests (+40) and instrumented tests (Mp3Decoder / AudioDecoder; compile-verified only, emulator not used)

## Notes
- Total JVM tests 851, 0 failures; assembleDebug + compileDebugAndroidTestKotlin green.
- Sample mapping: output sample s sits at decoder timeline s + encoderDelay + 529; encoderDelay = LAME tag value, else 576. Tagged length = frames*spf - startSkip - max(0, endPad-529) (ffmpeg convention). Audio frame 0 is the frame AFTER the Xing/Info frame.
- Mp3FrameReader.playableFrames walks real frame boundaries (exact); MixMath.streamPlayableFrames (byte-rate) remains for the headerless fallback.
- Voice window semantics: schedule(from,to,final); append(frontier) raises a growing window; ended only when window end reached AND final. Non-final end = hold (underrun), never ended.
- Engine must check VoiceGroup.allReady(minFrames) before startTogether (a voice with an empty ring at its start frame holds, which would desync stems).
- AudioTrackSink recreates on ANY audio-device add/remove at the fixed graph rate (platform resamples); the graph rate never changes. Device-only: audible behaviour, latency.

## Touched outside owned files
- android/app/build.gradle.kts: androidTest deps (androidx.test ext junit 1.2.1, runner 1.6.2) + androidTest resources srcDir src/test/resources (no androidTest existed before).
- Extra tests beyond the listed ones: AudioDiagTest, PcmBufferTest.

## Questions for Levi
- none

## Review

fixes applied

- MAJOR Mp3Decoder sampleRate/channels before open -> fixed: getters call ensureOpen(); `channels` is always `reader.channels` and fill() remaps the codec's layout to it (mono<->stereo), so Voice sees the file's real format and wraps in ConvertedSource. Tests: Mp3DecoderTest (fresh format; Voice over mono 22.05k mp3 reports sink-rate length; new fixture mono-22k-1s.mp3). Note: a codec that output a different SAMPLE RATE than the header is still not resampled here.
- MAJOR 529-sample over-skip -> fixed: discard = position + encoderDelay - first*spf (clamped), `Mp3Decoder.CODEC_TRIMS_DECODER_DELAY = true` (AOSP C2SoftMp3Dec/SoftMP3 trim 529 after start and flush). Reader's startSkip mapping (length, frameIndexForSample) is unchanged. NOT measured on emulator (not allowed in this pass): integrator should run Mp3DecoderInstrumentedTest.clickAtHalfASecondLandsWithin2msAfterStartAndAfterSeek (new fixture click-at-0p5s.mp3: silence then click at 0.5 s, asserts onset +-88 frames after start and after seek); if it fails by ~529, flip the constant. JVM test pins discardFor().
- MAJOR AudioTrackSink dead after failed recreate -> fixed: render loop retries recreate with backoff while track==null, re-reports onRoutingChanged(true) on recovery; track/route seams (TrackHandle, RouteWatcher) added so it is JVM-testable. Tests: AudioTrackSinkTest (failed recreate then self-recovery + re-report + clock advances; start no-op when running; initial build failure then start retry).
- MINOR route callback -> fixed: only sink devices, only changes after the registration snapshot (no rebuild on start, none for mics). Render/write wrapped in try/catch: isRendering=false, AudioDiag.stop(render-exception), loop survives and flips back to true on the next good block (test).
- MINOR setLoop stale position -> fixed: uses plan.from while a plan is unacknowledged (test). Flush avoidance: a redundant setLoop (same window) is a no-op with no flush (test). PARTIAL/rejected: clearing or changing a loop still re-seeks (flush). The ring already carries looped audio ahead of the play position and decodePos is decoder-thread private, so skipping the flush cannot be made race-free without a larger redesign; engine should avoid needless setLoop calls (and a VoiceGroup now holds all stems together across the refill, so no drift).
- MINOR ConvertedSource EOF -> fixed: EOF is sticky, every later call returns -1 once input is exhausted (mono / 22.05k / 32k rounded-length sources reach ENDED; test).
- MINOR gain ramp with lead -> fixed: curGain carries the partial ramp value so the next block continues from where it stopped (test with lead>0).
- MINOR VoiceGroup drift -> fixed: new VoiceGroup.read(outs, frames, blockStart) holds the whole group (silence, nothing consumed) if any voice would underrun (Voice.canFill/hold); startTogether returns -1 and starts nothing unless allReady(minFrames=1). Tests: VoiceGroupHoldTest. Engine should render stems through VoiceGroup.read.
- NIT fill() allocation -> fixed (reusable byte scratch; MediaCodec.BufferInfo now lazy).
- NIT androidTest deps -> fixed: moved to libs.versions.toml (androidx-test-ext-junit, androidx-test-runner). Integrator touchpoint: build.gradle.kts + libs.versions.toml.
