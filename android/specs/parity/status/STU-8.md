state: reviewed

# STU-8 — Instrument packs + SF2 synth engine (native) + on-screen keys + takes (click/count-in)

Summary: packs (tolerant manifest, offline-first index cache, streamed download with progress, sha256 verify, atomic install, bank-deduped, delete), `InstrumentEngine` over the STU-2 native TSF voice (`Sf2Synth`) rendered into the shared `AudioSink` (Oboe/AudioTrack) with off-main `loadInstrument`, thread-safe `InstrumentEventLog` (take + live streams, beat-1 anchored, highlight coalescing), `ClickTrack` metronome + 1-bar count-in mixed into LIVE output only, `startTake/stopTake`, replay (chase-aware), offline `TakeRenderer` (frame-exact event pump + -60 dBFS/3 s tail, multi-staff mix) and `TakeFiler` (file take, "Use as sample" COPIES audio), Instruments tab (Play / Takes / Packs) with a multi-touch piano.

Tests: +87 JVM tests (InstrumentPackStoreTest 14 + InstrumentPackGroupsTest 3, InstrumentEventLogTest 12, ClickTrackTest 10, InstrumentEngineTest 17, TakeRendererTest 14, TakeFilerTest 5, PianoLayoutTest 9, TakesCopyTest 3). Full `:app:testDebugUnitTest :app:assembleDebug` green: 3468 tests, 0 failures.

## Checklist
- [x] Endpoints (INSTRUMENTS_INDEX_URL / INSTRUMENTS_BASE / instrumentBankUrl: relative key appended to base), InstrumentPackModels, InstrumentPackStore (+ MockWebServer tests)
- [x] InstrumentEventLog + ClickTrack + tests
- [x] InstrumentEngine, TakeRenderer, TakeFiler + tests
- [x] UI: InstrumentsScreen, PianoKeyboard (+PianoLayout), PacksSection, TakesScreen; wiring (ProducerScreen, StudioGraph)
- [x] Full suite green at committed tip

## Deviations / notes
- Take AUDIO is rendered offline from the event log at stop (roadmap: "startTake/stopTake -> StudioTake + renderTake offline"), not tapped from the live output as on iOS. So the click and count-in are structurally never in a take; events are ms from beat 1 by the monotonic nano stamp. Live click is placed on the output frame counter, so audible click-vs-key alignment is only as good as the sink latency (device-only to judge).
- Event log uses `System.nanoTime` stamps (iOS host time). The OVERDUB stream and arpeggiator/MIDI input are NOT ported (not in this package's goal); live (free-play) and take streams are.
- Keys call the synth on the touch thread (no dispatcher hop; native synth serializes with a spinlock). `InstrumentEngine.DEBUG_THREADS` (set true in debuggable builds by InstrumentsScreen) logs the calling thread name per note-on via AudioDiag `studio.instr`.
- Output sink idles off after 5 s of nothing held/recording/replaying/clicking and wakes on the next note.
- Zero-length notes get a minimum 1 ms off (iOS sorts offs before ons at equal ms, which would hang such a note).
- Raw take file `take-<id>.m4a` is rendered once at record time from the raw events; edits/tempo/instrument changes use the existing render-cache (`take-<id>-r<N>.m4a`, renderRevision) via `TakeRenderer.render`, which also backs `StudioPrepareBackend.renderTake` (Collections playback of stale takes now works).
- Tempo rescale / instrument switch / rename / delete / folders are the existing STU-1 `StudioStore` ops (tempo rescale already unit-tested in StudioStoreTest; invalidate->re-render covered in TakeRendererTest).
- Extra files inside owned dirs: `studio/engine/TakeRenderer.kt` (TakeScore, TakeRenderer, TakeFiler), `InstrumentTestFakes.kt` and extra test classes.
- Touched outside owned files (minimal, additive): `di/StudioGraph.kt` (instrumentPacks / takeRenderer / takeFiler / instrumentEngine lazies + `renderTake` in prepareBackend), `screens/producer/ProducerScreen.kt` (Instruments sub-tab -> InstrumentsScreen).
- docs/ARCHITECTURE-ANDROID.md NOT edited (integrator).

## Device-only / unverified
- Real SF2 load/parse time of the 32 MB GeneralUser GS bank (`Sf2Synth` has no JVM coverage; only the fake `SynthVoice` is tested), Oboe key latency, click/key alignment.
- Emulator steps (live S3 bank download -> progress -> Piano enabled -> keys -> record with count-in -> replay) NOT run (emulator is the integrator's).
- Multi-touch glissando behaviour of the Compose pointer handler.

## Questions for Levi
- None blocking. Default: no SoundFont is bundled; the 32 MB bank is a user-initiated download (matches iOS).

## Review
fixes applied (3473 JVM tests, 0 failures; +5 new tests)
- MAJOR Sf2SynthVoice UnsatisfiedLinkError -> fixed: Sf2SynthVoice checks NativeDsp.available (loads the lib) and throws an Exception; loadInstrument catches Exception/LinkageError into loadError; TakeFiler catches Throwable (non-cancel). Tests: missingNativeLibraryIsALoadErrorNotACrash, missingNativeLibraryFailsTheFilingInsteadOfCrashing.
- MAJOR Cancel does not cancel -> fixed: read loop checks job activity, OkHttp Call is cancelled from cancelDownload, progress clears at once, a cancelled download never installs and is not an error. Test: cancelStopsTheDownloadAndNeverInstalls.
- MAJOR Click mid-take off the grid -> fixed: engine records takeBeat1Frame; setClickEnabled mid-take uses ClickTrack.nextBeatOnGrid and re-enters with bar phase kept (ClickTrack.Voice.start gained audibleFromFrame). Test: clickToggledMidTakeReentersOnTheTakesBeatGrid.
- MINOR Output latency -> fixed: beat1Nanos includes sink.latencyFrames() (buffer size on AudioTrack/Oboe). Test: takeBeat1IncludesOutputLatency. Still device-verify.
- MINOR Extra-staff voice leak -> fixed: voices come from engine.createVoice() (synthFactory) and are closed whenever replay() refuses or the call is cancelled. Per-bank voice caching NOT done (iOS backingSamplers pool) - follow-up.
- MINOR program mismatch -> fixed: gmProgram everywhere (as iOS); live loads no longer pass the manifest program.
- MINOR pump idle race / double retire -> fixed: idle decision + stopSink + pump=null in one locked step with re-check; backing swapped under the lock so finishReplay retires once. (Other take-state fields still not fully lock-guarded.)
- NIT sink pre-warm -> not done (optional).
