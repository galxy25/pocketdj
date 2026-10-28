state: merged

# STU-2 — Studio native DSP lib (cpp/pdjdsp) + OboeSink + StudioRender/RenderGraph + NDK Gradle wiring

Summary: one NDK module `libpdjdsp` (CMake, C++17, arm64-v8a + x86_64) with a thin JNI surface:
TrackFX/MasterFX kernels (line-for-line ports of TrackFX.swift/MasterFX.swift), a stereo mixer, a
TinySoundFont wrapper (one preset per synth, spinlock-serialized note/render), Signalsmith Stretch in
OFFLINE exact mode, and an Oboe output stream whose data callback only memcpy's from a lock-free SPSC ring
(no JNI, no allocation, no locks in the callback). Kotlin side: `OboeSink` (an `AudioSink`; render thread
feeds the ring, rebuilds a disconnected stream with 20/40/80/100 ms backoff and re-primes, clock advances per
block rendered), `NativeDsp` (JNI + Kotlin-fallback factories), `StudioAudio` (pure helpers + device/emulator
sink choice), `RenderGraph` (per-track source -> strip FX -> gain/pan -> sum -> master FX -> clamp, pull API,
`renderOffline` shares the live math), `StudioRender` (single-permit Mutex; carve, stem-mix, import (+DRM
reject), relabel import, renderSample with FX tail drain, renderLoop with exact frames, stretchBuffer,
transformBuffer, mixPCM; atomic temp+rename writes) and Kotlin kernel mirrors.

Tests: +72 new JVM tests (KernelsTest 12, StudioAudioTest 12, StudioRenderTest 30, RenderGraphTest 10,
OboeSinkTest 8). Full suite `:app:testDebugUnitTest :app:assembleDebug` green: 1438 tests (1366 before), 0
failures. `compileDebugAndroidTestKotlin` green (instrumented smoke compile-verified only).

## Checklist
- [x] NDK 27.2.12479018 + CMake 3.22.1 installed with sdkmanager (were NOT on this machine); Gradle externalNativeBuild, `prefab = true`, Oboe 1.9.3, abiFilters arm64-v8a + x86_64, c++_shared
- [x] cpp/pdjdsp: fx_kernels(.h), mixer(.h), sf2_voice(.h), stretch(.h), oboe_sink(.h), jni.cpp, CMakeLists.txt, third_party (tsf.h, signalsmith-stretch 1.4.0 + signalsmith-linear 0.6.4 vendored, licences kept)
- [x] Golden tool cpp/pdjdsp/tools/golden.cpp (host clang) -> app/src/test/resources/studio/fx-golden.txt; Kotlin kernels held to the C++ output within 1e-5 (track + master across a block boundary)
- [x] Host sanity run of the Signalsmith wrapper: exact length, 441 Hz survives 2x compression, +12 st doubles pitch, too-short input returns false (Kotlin falls back to the resampler)
- [x] OboeSink + NativeDsp + StudioAudio + RenderGraph + StudioRender + kernels
- [x] JVM tests; instrumented smoke `androidTest/.../studio/audio/StudioAudioInstrumentedTest.kt` (native-vs-Kotlin parity, native stretch, m4a decode -> loop wav -> sample m4a -> RenderGraph on AudioTrackSink 1 s). NOT run (emulator is the integrator's)
- [x] Acceptance mapping: 48k mono -> 44.1k stereo duration (StudioAudioTest); renderLoop exact frames + frame 0 = musical frame 0 + seam continuity + zero-pad (StudioRenderTest); renderSample = ceil(src/rate)+tail with -60 dBFS/3 s cap (StudioRenderTest); kernel golden parity (KernelsTest); sink rebuild (OboeSinkTest, scripted backoff well inside 300 ms)

## Deviations / notes
- Roadmap file list wins over the audit's: `cpp/pdjdsp` (not studiodsp), `OboeSink.kt` in audio/core, `StudioAudio.kt` in studio/audio. The audit's separate PcmBuffer/AudioDecoder/AacEncoder/WavWriter/AudioTrackOutput/StudioDiag files are NOT recreated: MIX-2's audio/core versions (PcmBuffer, AudioDecoder, AacEncoder, WavWriter, AudioTrackSink, AudioDiag) are reused.
- Extra files inside the owned dir: fx_kernels.h, mixer.h, sf2_voice.h, stretch.h, oboe_sink.h, tools/golden.cpp, studio/dsp kernels hold Biquad/Comb/AllPass; third_party/signalsmith-linear/*; test resource fx-golden.txt; androidTest StudioAudioInstrumentedTest; OboeSinkTest lives in audio/core tests.
- Touched outside owned files (minimal): `audio/core/PcmBuffer.kt` `resampled()` output length is now `ceil(frames*rate/sampleRate)` in integer math (was floor: a 48 kHz 1 s clip decoded to 44099 frames; iOS convertToCanonical returns ceil). Full suite re-run green. `android/.gitignore` += `.cxx/`.
- Realtime path: the Oboe callback is pure C++. The Kotlin feeder renders into a reusable buffer; `RenderGraph.render` allocates nothing per block (pan gains computed inline). `NativeTrackFx/NativeMasterFx` bridge planar<->interleaved with a reused scratch but the JNI shims allocate per-call planes (offline/control use only, not on the Oboe callback).
- Oboe clock: `clock` advances per block rendered into the ring (AudioTrackSink contract); `latencyFrames()` = ring-buffered + stream buffer.
- Sample FX voicing is an approximation of the Apple AUs (comp = 4:1 above a threshold of -30*wet dB with +15*wet dB makeup; filter = RBJ resonant LP Q 1.2 sweeping 18 kHz -> 250 Hz; reverb = the TrackFX Freeverb-lite as a send; delay = fixed 0.3 s / 30 % feedback slap crossfade). Audition and bake share `StudioRenderCore.SampleFx`, so they agree with each other; matching the iOS sound exactly is a listening task.
- Tail drain deviates from iOS in one safe way: a silent window does not end the drain while the slap-delay line still holds audible energy (iOS would stop in the gap before the first echo of a short sample).
- No AAC priming-head trim: native Signalsmith `exact()` is aligned (no latency head) and the neutral path is a copy. The AAC encoder's own priming on the written m4a is MIX-2/AacEncoder territory; the instrumented smoke logs decoded duration (60 ms tolerance) so the integrator can see whether round-trip alignment needs a head trim.
- NOT ported here (their inputs belong to later Studio packages): pattern bounce (`bouncePattern`, needs StudioEngine step clock), SoundFont take renders (`renderTake`/polyphonic; use `Sf2Synth` + `StudioRender.mixPCM`), `StudioDiag` (use `AudioDiag`).
- Loop files are float32 LPCM `.wav` (documented STU-1 divergence from CAF). Decoding float WAV through MediaExtractor/MediaCodec is unverified on the emulator (covered by the instrumented smoke).

## Device-only / unverified
- Oboe low-latency path, real latency, exclusive-mode availability, route-change (headphones/BT) rebuild timing; emulator uses AudioTrackSink via `StudioOutputs.create`.
- SF2 load/render (`Sf2Synth`) has no JVM or host test (needs a SoundFont file); first exercised by the instrumented/instrument packages.
- `StudioOutputs.create` is not wired to any engine yet (engine packages call it).

## Questions for Levi
- GeneralUser GS (or another SF2) licensing/packaging for the instrument packs is still undecided; `Sf2Synth` loads any `.sf2` path. (Default: instrument pack downloads, nothing bundled.)

## Review
Tests after fixes: 1447 run, 0 failed (new: pan near-unity + half-pan, retire-queue in-flight/idle, bounce normalize, live limiter, underrun no-double-count, 300 ms deterministic rebuild, routing-false once, loop window exactness).

1. MAJOR pan law -> fixed. RenderGraph now uses the iOS centre-unity linear balance (L=1 / 1-p, R=1 / 1+p); tests assert near side unity and pan 0.5 => L 0.5, R 1.0.
2. MAJOR FX use-after-free -> fixed. removeTrack/release queue the FX on a retire queue; freed only when no render is in flight (tryLock) or at the next render() block boundary. NativeTrackFx/NativeMasterFx handles are @Volatile and every call is a no-op at h==0. Test: removal during an in-flight render does not close until the next block.
3. MINOR abiFilters / libc++_shared -> documented, not changed. abiFilters arm64-v8a+x86_64 intentionally drops armeabi-v7a (minSdk 35 devices are 64-bit; 32-bit-only Apple Music native libs are lost). c++_shared swaps in NDK libc++ over the one in mediaplayback-1.1.1.aar. NEEDS DEVICE CHECK by the integrator: Apple Music full-track playback after this change. Fallback if it regresses: link pdjdsp with c++_static.
4. MINOR underrun double count -> fixed. Native counter is cumulative across reopen; sink no longer accumulates a base. Test across failed+successful rebuilds.
5. MINOR OboeSink error handling -> fixed. (a) 50 ms backoff after render exception; (b) onRoutingChanged(false) fires once on the transition into disconnected (the later true reports recovery; per-failed-retry reports omitted to avoid spam); (c) stop() joins until the feeder is dead before freeing the native handle.
6. MINOR AAC priming on m4a bakes -> deferred, not fixable without a device measurement (emulator off-limits). The instrumented smoke now asserts the decoded onset is within ~1 ms (44 frames) instead of tolerating 60 ms, so the integrator's emulator run will show whether a head exists; if so trim/edts in AudioDecoder/AacEncoder (MIX-2 coordination). Loops are WAV and unaffected.
7. MINOR JNI allocation -> fixed. Track/master FX shims use stack scratch in 512-frame chunks and GetPrimitiveArrayCritical (no malloc, no array copy); h==0 guarded.
8. MINOR hard clamp -> fixed. Live path: peak limiter (instant attack, ~50 ms release) with clamp as safety net; offline bounce renders unlimited then scales by 1/peak when peak>1 (iOS ArrangerBouncer).
9. MINOR PcmBuffer floor->ceil -> rejected. Ceil is the iOS convertToCanonical contract ("never one frame short") and the Studio frame-exact guarantees depend on it; flagged to the integrator/MIX owners as a shared touchpoint: PcmBuffer.resampled() frame count can grow by <=1 frame for every Mix resample.
10. MINOR nominal acceptance -> partly fixed. 300 ms criterion now asserted at <=300 ms on the injected clock via pumpOnce; seam test supplemented with a unique-valued source + anchor offset asserting exact contiguous window; instrumented smoke / StrictMode run / ARCHITECTURE-ANDROID.md ledger row remain for the integrator (emulator not used, docs file absent in this worktree).
11. NIT sf2 lock -> fixed. New tsf is configured outside the lock, pointer swapped under it, old freed after unlock; GetStringUTFChars null-checked.

fixes applied
