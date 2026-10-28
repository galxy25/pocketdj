state: implemented

# STU-3 — Producer shell + Samples (mic, import, from-track) + sample editor + mixer deck + StudioEngine

Summary: the Producer placeholder is replaced by a 7-segment sub-tab shell (persisted `studioTab`, icon-only under 600 dp) with a live Samples tab:
folders / move-to / rename / delete-with-referrers, record from mic, import via SAF (DRM rejected), new-from-track (search, burn-on-demand ladder
burning / ready / failed+Retry / "Rip first", waveform with draggable in/out, mark in/out, nudge +/-10 ms and +/-1 beat, carve inheriting the
offset-shifted grid), and the editor (waveform trim, reusable MixerDeck, tap-tempo / manual BPM / auto-detect, implicit render cache).

Tests: +98 new JVM tests (BeatMath 16, BeatDetect 9, MicRecorderMath 11, LocalAudioCache 13, StudioEngine 21, SampleFactory 8, ProducerLogic 20).
Full `:app:testDebugUnitTest :app:assembleDebug` green: 2004 tests (1906 before), 0 failures.

## Checklist
- [x] BeatMath (lastBeat/isDownbeat/sliceBoundaries/sliceStarts/cyclePhase-free subset + shifted/inheritedGrid) and BeatDetect (55-210 search, 70-180 report, octave fold pinned)
- [x] AudioFocusPolicy (micCaptureActive guard + AudioFocus handle), MicRecorder (AudioRecord, input picker, level meter, stall watchdog, stopAwaitingFinalize, orphan recovery, crash-safe WAV take)
- [x] LocalAudioCache (phase ladder + atomic, in-flight-deduped downloader), wired to BurnStore / rips manifest / presign in StudioGraph
- [x] StudioEngine sample audition (SampleAuditionSource live gain/FX/trim, async rate/pitch reshape, loop, slice one-shot, FX tail) + SampleRenderCache (renderRevision-gated)
- [x] SampleFactory (import w/ DRM reject, track carve w/ analog offset contract)
- [x] StudioSettings (studioTab pref via PrefKey, no AppSettingsStore edit), StudioSubTab
- [x] Widgets: WaveformView, EditSlider, MixerDeck, FolderRows
- [x] SamplesScreen, MicRecordSheet, NewSampleFromTrackSheet, SampleEditorSheet, ProducerScreen/ProducerRoutes
- [x] Full suite green at the committed tip

## Deviations / notes
- Mic takes are mono PCM16 WAV written under the sample's `sample-<id>.m4a` file name (decoders sniff content; same convention as STU-1's seed). Reason: MediaMuxer/AAC is not crash-safe (moov at end), and orphan recovery needs a file readable after a kill. The RIFF header is re-patched every ~1 s and recovery trusts the byte length. ~5 MB/min. A later pass can transcode finished takes to AAC.
- Mic/import/carve write ONLY to the app-managed samples root (`wasUserFolder=false`); copy-out to a SAF user root is not done (reads of user-root files still work through StudioFolders).
- Stem-subset carve (iOS stem mode in the from-track sheet) is NOT ported (belongs with the Demuxer/stem packages); full-mix carve only.
- LocalAudioCache delegates the burn to BurnStore (per the architecture note); its own downloader (studio-src cache) is the fallback when the burn folder is unreachable.
- Auto-detect BeatDetect: the autocorrelation uses a 3-lag box smoothing + centroid refinement (the iOS integer-lag version is ~2 BPM coarse at 150 BPM and prefers the half-tempo for accented clicks); search/report ranges are as iOS.
- Rate/pitch audition: the whole raw buffer is re-fitted off-thread (latest wins) rather than a realtime stretcher; gain/filter/comp/reverb/delay are live per block. The pull path takes a short lock (Kotlin feeder thread, not the Oboe callback).
- FX voicing is the STU-2 `SampleFx` approximation; matching the iOS AU sound exactly is a listening task.
- Files touched outside the owned list (all minimal/additive): `studio/store/StudioFolders.kt` (`FileStudioDir.dir` made public so renders/recordings can get a real File), `shell/ShellNavigation.kt` (Producer now routes to `ProducerRoute`; was PlaceholderScreen), `di/StudioGraph.kt` (lazy engine/recorder/render/cache wiring; ON_STOP flushable finalizes an in-flight take). Extra new files: `studio/engine/SampleRenderCache.kt`, `studio/engine/SampleFactory.kt`, and tests `StudioEngineTest`, `SampleFactoryTest`, `ProducerLogicTest`. AndroidManifest already declared RECORD_AUDIO; RipsModels already had the beatgrid/stems fields; AppSettingsStore untouched (PrefKey).
- ON_STOP finalizes (files) an in-flight take: Android blocks background mic capture.
- Producer sub-tabs other than Samples show "Coming soon" until their packages land.

## Device-only / unverified
- Real mic quality, Bluetooth/USB input picker, DRM rejection with a real protected file, SAF import from a real provider, Oboe latency of the audition sink. Emulator steps (record 2 s with -allow-host-audio, import tone.wav, from-track against live manifest, screenshots) NOT run (emulator is the integrator's).

## Questions for Levi
- Should finished mic takes be transcoded WAV -> AAC m4a after stop (smaller files) or stay WAV? (Default: WAV.)
- Should samples be copied out to the SAF user samples folder when one is configured? (Default: app root only.)
