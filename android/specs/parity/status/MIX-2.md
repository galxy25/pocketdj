state: implemented

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
