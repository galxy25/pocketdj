"""Final packages — games (GM), mix (MIX), studio (STU)."""
from spec_common import M, T, A, R, TR, CPP, MANIFEST, GRADLE, TOML, ARCH_DOC, m, t
from spec_part1 import P

PACKAGES = [
    # ───────────────────────────── GAMES ─────────────────────────────
    P("GM-1", "games", src=["GAMES-1"],
      title="Games tab (7th destination via nav registry) + Scoreboard store (tombstones, union merge) + GamesGraph wiring",
      files=m("data/games/GameKind.kt", "data/games/GameScoreboardModels.kt", "data/games/GameScoreboardStore.kt", "data/games/GamesPrefs.kt", "di/GamesGraph.kt", "screens/games/GamesScreen.kt", "screens/games/GamesRoutes.kt")
            + t("data/games/GameScoreboardStoreTest.kt", "data/games/ScoreboardMergeTest.kt"),
      deps=["SURF-1", "PB-5"], est=1100, prio="P0", rank=9),

    P("GM-2", "games", src=["GAMES-2"],
      title="Gem Collector core: settings, recency, sampler, similarity, decision store, rec bridge (pure)",
      files=m("data/games/puzzle/PuzzleSettings.kt", "data/games/puzzle/PlayRecency.kt", "data/games/puzzle/PuzzleSampler.kt", "data/games/puzzle/PuzzleSimilarity.kt", "data/games/puzzle/PuzzleDecisionStore.kt", "data/games/puzzle/PuzzleRecEventBridge.kt")
            + t("data/games/puzzle/PuzzleSamplerTest.kt", "data/games/puzzle/PuzzleSimilarityTest.kt", "data/games/puzzle/PuzzleDecisionStoreTest.kt", "data/games/puzzle/PlayRecencyTest.kt"),
      deps=[], est=2300, prio="P0", rank=0),

    P("GM-3", "games", src=["GAMES-3"],
      title="Gem Collector engine + GameRunPlayer over the sequencer (appendRows(runTag), preview-resolving, chunked lookahead 12)",
      files=m("playback/GameRunPlayer.kt", "playback/SequencerGameRunPlayer.kt", "data/games/puzzle/CollectorsPuzzleEngine.kt", "di/GamesGraph.kt")
            + t("data/games/puzzle/CollectorsPuzzleEngineTest.kt", "playback/GameRunPlayerContractTest.kt"),
      deps=["GM-1", "GM-2", "PB-1"], est=1700, prio="P0", rank=13,
      device="Apple Music preview resolution needs network; full-track AM is deliberately never used in game runs."),

    P("GM-4", "games", src=["GAMES-4"],
      title="Gem Collector screens (setup / countdown / running / summary) + multi-collection filing via the Add-to sheet",
      files=m("screens/games/CollectorsPuzzleScreen.kt", "screens/games/PuzzleGenreScreen.kt", "screens/games/PuzzleComponents.kt", "di/GamesGraph.kt") + t("screens/games/PuzzleScreenLogicTest.kt"),
      deps=["GM-1", "GM-2", "GM-3", "COL-4"], est=1400, prio="P0", rank=17),

    P("GM-5", "games", src=["GAMES-5"],
      title="In the Pocket core: models, pockets results decode (PocketsModels owner), scorer, membership, learning, evaluator, rounds wire (pure)",
      files=m("data/pockets/PocketsModels.kt", "data/games/inthepocket/InThePocketModels.kt", "data/games/inthepocket/SplitMix64.kt", "data/games/inthepocket/InThePocketScorer.kt", "data/games/inthepocket/InThePocketMembership.kt",
              "data/games/inthepocket/InThePocketLearning.kt", "data/games/inthepocket/InThePocketRoundEvaluator.kt")
            + t("data/games/inthepocket/InThePocketScorerTest.kt", "data/games/inthepocket/InThePocketLearningTest.kt", "data/games/inthepocket/RoundEvaluatorTest.kt", "data/pockets/PocketsModelsTest.kt", "data/games/inthepocket/SplitMix64Test.kt"),
      deps=[], est=2400, prio="P1", rank=19),

    P("GM-7", "games", src=["GAMES-7"],
      title="In the Pocket store + PocketsBridge interface (NoPocketsBridge default) + rounds upload client",
      files=m("data/pockets/PocketsBridge.kt", "data/games/inthepocket/InThePocketStore.kt", "data/games/inthepocket/InThePocketRoundsClient.kt", "data/games/inthepocket/InThePocketInputs.kt", "di/GamesGraph.kt") + [R + "xml/backup_rules.xml"]
            + t("data/games/inthepocket/InThePocketStoreTest.kt", "data/games/inthepocket/RoundsClientTest.kt"),
      deps=["GM-1", "GM-3", "GM-5", "PB-5"], est=1400, prio="P1", rank=29),

    P("GM-8", "games", src=["GAMES-8"],
      title="In the Pocket screen + on-device feedback dictation",
      files=m("screens/games/InThePocketScreen.kt", "screens/games/InThePocketComponents.kt", "screens/games/PocketsOptInView.kt", "data/games/inthepocket/FeedbackDictation.kt", "di/GamesGraph.kt")
            + t("screens/games/InThePocketScreenLogicTest.kt"),
      deps=["GM-7"], est=1200, prio="P1", rank=39,
      device="SpeechRecognizer dictation needs a real microphone/Google app; emulator verifies the typed-feedback path."),

    P("GM-9", "games", src=["GAMES-9"],
      title="Music with Friends link, models, client, join secret, session file, store (broker-driven, polling, no UI)",
      files=m("data/games/friends/MwFLink.kt", "data/games/friends/MwFModels.kt", "data/games/friends/MwFClient.kt", "data/games/friends/MwFJoinSecret.kt", "data/games/friends/MwFSessionFile.kt", "data/games/friends/MusicWithFriendsStore.kt", "di/GamesGraph.kt")
            + t("data/games/friends/MwFLinkTest.kt", "data/games/friends/MwFClientTest.kt", "data/games/friends/MusicWithFriendsStoreTest.kt"),
      deps=["GM-1", "GM-3"], est=1600, prio="P1", rank=31),

    P("GM-10", "games", src=["GAMES-10"],
      title="Music with Friends screens + deep-link handler (pocketdj://mwf, https /mwf/) + Games home session rows",
      files=m("screens/games/MwFCreateSheet.kt", "screens/games/MwFJoinSheet.kt", "screens/games/MwFSessionScreen.kt", "screens/games/MwFComponents.kt", "screens/games/GamesScreen.kt", "data/games/friends/MwFDeepLinkHandler.kt", "di/GamesGraph.kt")
            + t("screens/games/MwFScreenLogicTest.kt", "data/games/friends/MwFDeepLinkHandlerTest.kt"),
      deps=["GM-1", "GM-9", "SURF-4"], est=1600, prio="P1", rank=41,
      device="https App Link auto-verification needs /.well-known/assetlinks.json on jukebox.pocket-dj.com; pocketdj:// works on the emulator."),

    # ───────────────────────────── MIX ─────────────────────────────
    P("MIX-0", "mix", src=["MIX-0"],
      title="Mix models, FX rack types, pure math (BeatMath, MixMath, Camelot, FxParams)",
      files=m("mix/model/MixModels.kt", "mix/model/FxRack.kt", "mix/model/MixMath.kt", "mix/model/BeatMath.kt", "mix/model/Camelot.kt")
            + t("mix/model/MixMathTest.kt", "mix/model/BeatMathTest.kt", "mix/model/FxParamsTest.kt", "mix/model/CamelotTest.kt"),
      deps=[], est=1600, prio="P0", rank=0),

    P("MIX-1", "mix", src=["MIX-1"],
      title="Durable Mix stores over the shared VersionedJsonWriter: MixDeckSessionStore (decks v1) + MixSessionStore (sessions v2), iOS fixtures",
      files=m("mix/store/MixDeckSessionStore.kt", "mix/store/MixSessionModels.kt", "mix/store/MixSessionStore.kt", "di/MixGraph.kt") + [TR + "mix/ios-mix-decks-v1.json", TR + "mix/ios-mix-sessions-v2.json"]
            + t("mix/store/MixDeckSessionStoreTest.kt", "mix/store/MixSessionStoreTest.kt"),
      deps=["MIX-0", "COL-2"], est=1300, prio="P0", rank=4),

    P("MIX-2", "mix", src=["AUD-1"], partial=["STU-2"],
      title="Shared audio core (`audio/`): AudioSink + AudioTrackSink, RenderClock, FloatRing, PcmSource, Mp3FrameReader, MediaCodec Mp3Decoder + generic AudioDecoder, WavWriter, AacEncoder, OfflineRenderer, Voice, VoiceGroup, AudioDiag",
      goal=("Decision D1. The ONE platform audio layer for Mix, Studio and Now Playing DSP: `AudioSink` interface + `AudioTrackSink` (float PCM, low-latency, urgent-audio render thread, renderFrame clock, underrun counter, routing-changed callback, isRendering); "
            "`OfflineRenderer` for JVM/instrumented probes; `PcmSource` + `Mp3FrameReader` (sync walk, MPEG1/2 L3, Xing/Info/VBRI, LAME delay, 576-sample priming rule, playableFrames(bytesFrontier)) + `Mp3Decoder` (MediaCodec sync) + generic "
            "`AudioDecoder` (MediaExtractor/MediaCodec → canonical 44.1k stereo Float32 for m4a/wav/mp3, Studio's decoder) + `WavWriter` + `AacEncoder` (MediaCodec AAC-LC, m4a + ADTS modes); `Voice`/`VoiceGroup` (four stems start on ONE frame, "
            "mono upmix, linear resample fallback); `SyntheticPcmSource`; `AudioDiag` reason-tagged play()/stop() exits (the iOS 'no sound vs never called' lesson)."),
      files=m("audio/core/AudioSink.kt", "audio/core/AudioTrackSink.kt", "audio/core/OfflineRenderer.kt", "audio/core/RenderClock.kt", "audio/core/FloatRing.kt", "audio/core/PcmSource.kt", "audio/core/SyntheticPcmSource.kt",
              "audio/core/Mp3FrameReader.kt", "audio/core/Mp3Decoder.kt", "audio/core/AudioDecoder.kt", "audio/core/PcmBuffer.kt", "audio/core/WavWriter.kt", "audio/core/AacEncoder.kt", "audio/core/Voice.kt", "audio/core/VoiceGroup.kt", "audio/core/AudioDiag.kt")
            + [TR + "mix/tagged-lame-2s.mp3", TR + "mix/untagged-lame-2s.mp3", A + "audio/core/Mp3DecoderInstrumentedTest.kt", A + "audio/core/AudioDecoderInstrumentedTest.kt"]
            + t("audio/core/Mp3FrameReaderTest.kt", "audio/core/VoiceTest.kt", "audio/core/VoiceGroupOneFrameTest.kt", "audio/core/FloatRingTest.kt", "audio/core/WavWriterTest.kt", "audio/core/OfflineRendererTest.kt"),
      deps=["MIX-0", "SVC-5"], est=2500, prio="P0", rank=4,
      acc=["Studio (STU-2) and Mix (MIX-4) both build on this package with no second decoder/sink/renderer anywhere in the tree (grep-asserted in STU-16)"],
      device="Audible output and AudioTrack low-latency behaviour on real hardware."),

    P("MIX-3", "mix", src=["AUD-2"],
      title="Shared DSP nodes (`audio/dsp`): Biquad/Eq3/Trim, TimePitch (Sonic), Compressor, Reverb, ModDelay, Limiter, Meter, EnvelopeFollower, FxSlotNodes",
      files=m("audio/dsp/Biquad.kt", "audio/dsp/Eq3.kt", "audio/dsp/TrimGain.kt", "audio/dsp/TimePitch.kt", "audio/dsp/Compressor.kt", "audio/dsp/Reverb.kt", "audio/dsp/ModDelay.kt", "audio/dsp/Limiter.kt", "audio/dsp/Meter.kt", "audio/dsp/EnvelopeFollower.kt", "audio/dsp/FxSlotNodes.kt")
            + t("audio/dsp/BiquadTest.kt", "audio/dsp/TimePitchTest.kt", "audio/dsp/LimiterTest.kt", "audio/dsp/MeterTest.kt", "audio/dsp/FxSlotNodesTest.kt"),
      deps=["MIX-0"], est=1900, prio="P0", rank=4),

    P("MIX-4", "mix", src=["AUD-3"],
      title="MixGraph: deck chains, house/cue/limiter, taps, render-thread handover + parameter snapshot",
      files=m("mix/graph/MixGraph.kt", "mix/graph/DeckChain.kt", "mix/graph/RenderParams.kt", "mix/graph/Taps.kt", "mix/graph/Handover.kt")
            + t("mix/graph/MixGraphRenderTest.kt", "mix/graph/HandoverTest.kt", "mix/graph/RenderParamsSnapshotTest.kt"),
      deps=["MIX-2", "MIX-3"], est=1500, prio="P0", rank=11),

    P("MIX-5", "mix", src=["MIX-2"],
      title="MixEngine core: decks, load/seek/transport, EQ, FX rack, Vol/crossfader, cue, lead/sync, VU, 10 Hz tick, session-log hooks, durable persistence",
      files=m("mix/engine/MixEngine.kt", "mix/engine/EngineCore.kt", "mix/engine/DeckController.kt", "mix/engine/MixUiState.kt", "mix/engine/MixPersistence.kt", "mix/engine/MixRecordingHooks.kt", "mix/engine/MixTick.kt", "di/MixGraph.kt")
            + t("mix/engine/MixEngineTransportTest.kt", "mix/engine/MixEnginePersistenceTest.kt", "mix/engine/CrossfaderSyncTest.kt"),
      deps=["MIX-0", "MIX-1", "MIX-4", "SVC-2"], est=2500, prio="P0", rank=14),

    P("MIX-6", "mix", src=["DL-2"],
      title="MixStreamLoader: growing-file song streams (public rips object + Range) + stem sets, adopted into BurnStore when complete",
      files=m("mix/stream/MixStreamLoader.kt", "mix/stream/StreamSink.kt", "mix/stream/NetworkMonitor.kt", "di/MixGraph.kt")
            + t("mix/stream/MixStreamLoaderTest.kt", "mix/stream/StreamSinkTest.kt"),
      deps=["SVC-2", "SVC-1"], est=1300, prio="P0", rank=12),

    P("MIX-7", "mix", src=["DL-3"],
      title="MixResolver + CollectionMixDownloader (collection pull with progress/ETA + progressive eligibility) + AutoMixHost",
      files=m("mix/download/MixResolver.kt", "mix/download/CollectionMixDownloader.kt", "mix/download/AutoMixHost.kt", "di/MixGraph.kt")
            + t("mix/download/MixResolverTest.kt", "mix/download/CollectionMixDownloaderTest.kt"),
      deps=["MIX-0", "SVC-2", "SVC-3", "MIX-6"], est=1400, prio="P0", rank=16),

    P("MIX-8", "mix", src=["MIX-3"],
      title="Loop (∞) + stem decks + zero-dead-air handover + beat-grid hydrate",
      files=m("mix/engine/LoopController.kt", "mix/engine/StemController.kt", "mix/engine/BeatGridHydrator.kt")
            + t("mix/engine/LoopWindowTest.kt", "mix/engine/StemHandoverTest.kt", "mix/engine/BeatGridHydratorTest.kt"),
      deps=["MIX-5", "MIX-6", "SVC-11"], est=2400, prio="P0", rank=18),

    P("MIX-9", "mix", src=["MIX-4"],
      title="Auto-DJ machine + readiness rules + glide + remote freeze + jukebox queue seams",
      files=m("mix/engine/AutoDj.kt", "mix/engine/AutoReadiness.kt", "mix/engine/GlideMachine.kt", "mix/engine/AutoQueueSeams.kt")
            + t("mix/engine/AutoDjTest.kt", "mix/engine/AutoReadinessTest.kt", "mix/engine/GlideMachineTest.kt"),
      deps=["MIX-5", "MIX-8"], est=2500, prio="P0", rank=22),

    P("MIX-10", "mix", src=["MIX-5"],
      title="Streaming decks in the engine (growing-file playback, hold/resume, truncation, stem streams, Buffering… state)",
      files=m("mix/engine/StreamDecks.kt") + t("mix/engine/StreamDecksTest.kt"),
      deps=["MIX-5", "MIX-8", "MIX-6"], est=1300, prio="P0", rank=22),

    P("MIX-11", "mix", src=["MIX-6"],
      title="Mix transport owner: MixSessionPlayer (SimpleBasePlayer TransportOwner) into the ONE MediaSession, audio focus, routing recovery, MixDiag heartbeat",
      goal=("Decision D2 variant of MIX-6: no MixService. `MixSessionPlayer : SimpleBasePlayer` adapts nowPlayingDeck (title/artist/art/duration/position/rate=tempo, ~1 Hz) and commands (play→remotePlay, pause→remotePause, "
            "next→remoteSkip(5), previous→remoteSkip(skipFadeSeconds), no ♥), implements `TransportOwner` and registers with `SessionSwitchboard` (last-STARTED owns; Mix start pauses the sequencer); `MixAudioFocus` "
            "(GAIN on start, transient loss → remotePause + interruptionParked latch, regain resumes only what was parked, LOSS → pauseBoth, becoming-noisy → remotePause); `MixRecovery` on routing/device change "
            "(recreate AudioTrack, re-prime voices, resume at the frozen frame); `MixDiag` `[mix] hb render=1 tapAge sigAge` lines + export row in the Mix settings section."),
      files=m("mix/service/MixSessionPlayer.kt", "mix/service/MixAudioFocus.kt", "mix/service/MixRecovery.kt", "mix/service/MixDiag.kt", "di/MixGraph.kt")
            + t("mix/service/MixSessionPlayerTest.kt", "mix/service/MixRecoveryTest.kt", "mix/service/MixAudioFocusTest.kt"),
      deps=["MIX-9", "PB-2"], est=1400, prio="P0", rank=26,
      device="Bluetooth route changes, phone-call interruption, headset buttons, real lock screen."),

    P("MIX-12", "mix", src=["MIX-7"],
      title="Mix session audio recording (house tap → ADTS AAC) + MixRecorder + orphan recovery + RecordingPlayer",
      files=m("mix/recording/TapSink.kt", "mix/recording/AacAdtsWriter.kt", "mix/recording/SessionFolders.kt", "mix/recording/MixRecorder.kt", "mix/recording/RecordingPlayer.kt", "data/storage/StorageService.kt", "di/MixGraph.kt")
            + [A + "mix/recording/AacAdtsWriterInstrumentedTest.kt"] + t("mix/recording/MixRecorderTest.kt", "mix/recording/SessionFoldersTest.kt"),
      shared=[M + "data/storage/StorageService.kt (MIX_SESSIONS category)"],
      deps=["MIX-4", "MIX-1", "MIX-5"], est=1300, prio="P1", rank=30),

    P("MIX-13", "mix", src=["UI-1"],
      title="Deck UI: DeckView + controls (sliders/knobs/steppers), seek slider, FX chips, stem pads, VU meter, loop chip, cue button (cueJumpRow slot), beat pulse, waveform, crossfader, master transport",
      files=m("screens/mix/DeckView.kt", "screens/mix/DeckControls.kt", "screens/mix/DeckSeekSlider.kt", "screens/mix/FxSlotChip.kt", "screens/mix/StemPad.kt", "screens/mix/DeckVuMeter.kt", "screens/mix/LoopChip.kt", "screens/mix/CueButton.kt",
              "screens/mix/CuePointsProvider.kt", "screens/mix/BeatPulse.kt", "screens/mix/MixWaveform.kt", "screens/mix/CrossfaderView.kt", "screens/mix/MixBufferingBadge.kt", "screens/mix/DeckArea.kt")
            + t("screens/mix/DeckControlMathTest.kt", "screens/mix/BeatPulsePhaseTest.kt"),
      deps=["MIX-5", "MIX-8"], est=2400, prio="P0", rank=24),

    P("MIX-14", "mix", src=["UI-2"],
      title="Mix screen shell: session header, Auto setup bar/banner/skip, crate menus A/B (scroll reset), download bar, loader sheet, Settings ▸ Mix section, route registration",
      files=m("screens/mix/MixScreen.kt", "screens/mix/MixViewModel.kt", "screens/mix/SessionHeader.kt", "screens/mix/AutoMixBars.kt", "screens/mix/MixCrateMenu.kt", "screens/mix/DownloadBar.kt", "screens/mix/TrackLoaderSheet.kt",
              "screens/mix/MixRoutes.kt", "screens/settings/sections/MixSection.kt", "mix/MixSettings.kt", "di/MixGraph.kt")
            + t("screens/mix/MixViewModelTest.kt", "screens/mix/CrateMenuStateTest.kt"),
      deps=["MIX-13", "MIX-9", "MIX-10", "MIX-7", "MIX-1", "MIX-11"], est=2300, prio="P0", rank=28),

    P("MIX-15", "mix", src=["UI-3"],
      title="Sessions screen + replay timeline + recordings panel",
      files=m("screens/mix/MixSessionsScreen.kt", "screens/mix/MixReplayTimeline.kt", "screens/mix/MixEventSentences.kt") + t("screens/mix/MixEventSentencesTest.kt", "screens/mix/ReplayTimelineTest.kt"),
      deps=["MIX-1", "MIX-14", "MIX-12"], est=1200, prio="P1", rank=45),

    P("MIX-16", "mix", src=["INT-1"],
      title="Integrations: Jukebox ↔ Mix seams, MixPlayOutcomeBridge → History, MixFacade implementation for ShellActions, docs update (resolved open question #1, Mix ledger row)",
      files=m("mix/engine/MixPlayOutcomeBridge.kt", "mix/MixFacadeImpl.kt", "data/jukebox/JukeboxRepository.kt", "data/jukebox/MixJukeboxSource.kt", "di/MixGraph.kt") + [ARCH_DOC, "android/specs/mix.md"]
            + t("mix/engine/MixPlayOutcomeBridgeTest.kt", "data/jukebox/MixJukeboxSourceTest.kt", "mix/MixFacadeImplTest.kt"),
      shared=[M + "data/jukebox/JukeboxRepository.kt (Mix placement seam)", ARCH_DOC],
      deps=["MIX-9", "MIX-11", "SURF-5", "PB-5", "SURF-10", "MIX-14"], est=1100, prio="P1", rank=47),

    P("MIX-17", "mix", src=["MIX-8"],
      title="Slot modulation (LFO beat-locked + envelope follower) on the FX rack",
      files=m("mix/engine/ModController.kt", "screens/mix/SlotModSheet.kt") + t("mix/engine/ModControllerTest.kt"),
      deps=["MIX-8", "MIX-13", "MIX-14"], est=1100, prio="P2", rank=88),

    P("MIX-18", "mix", partial=["PB-6", "MIX-3", "AUD-3"],
      title="Now Playing Mix mini-panel (F4: swap-on-touch ExoPlayer→DSP hand-off, stems/effects/tempo/pitch/gain) + Stem Lock (per-session stem set carry, song-then-stems prefetch V>D>O>B, indicator states)",
      goal=("The iOS F4 + Stem Lock features both audits deferred to each other (see memory f4-mix-nowplaying + nowplaying-stem-lock). Implements PB-6's `NowPlayingDspSeam` (engage(file,startMs,lengthMs,atSeconds,play)/disengage/isPlaying/currentTimeSec/rate/onReachedEnd) "
            "with a `NowPlayingDspEngine` built from the shared `Voice` + `Handover` + DSP nodes rendered through the Mix `AudioSink`, presented to the ONE MediaSession as a TransportOwner through SessionSwitchboard (never a second card); "
            "hidden for non-local tracks or while a Mix session runs (`mixSessionActive` gate). `StemLock` carries the stem set across tracks, `StemLockPrefetcher` fetches song then stems V>D>O>B via BurnStore, indicator off/idle/loading/active/unavailable, "
            "persisted in the durable session's `stemLock` object (PB-4 reserved it)."),
      files=m("screens/nowplaying/NowPlayingDspPanel.kt", "screens/nowplaying/StemLockIndicator.kt", "mix/nowplaying/NowPlayingDspEngine.kt", "mix/nowplaying/StemLock.kt", "mix/nowplaying/StemLockPrefetcher.kt", "di/MixGraph.kt")
            + t("mix/nowplaying/NowPlayingDspEngineTest.kt", "mix/nowplaying/StemLockTest.kt", "mix/nowplaying/StemLockPrefetcherOrderTest.kt"),
      deps=["PB-6", "PB-4", "MIX-8", "MIX-11", "SVC-11"], est=1800, prio="P1", rank=50,
      acc=["Touching a DSP control mid-song hands off from ExoPlayer to the DSP engine within one block with no audible gap and the lock-screen card stays single", "Stem Lock survives track change and session restore; prefetch order is song, vocals, drums, other, bass", "Panel hidden for non-local rows and while a Mix session is active"],
      ut=["NowPlayingDspEngineTest: engage/disengage state machine + onReachedEnd", "StemLockTest: carry + persistence shape", "StemLockPrefetcherOrderTest: V>D>O>B order, cancellation on skip"],
      emu=["Burn a song, open Now Playing, toggle a stem: indicator loading→active; skip to the next burned song, stem set carried; kill + relaunch → indicator restored idle/active per session"],
      device="Audible seamless hand-off and route changes."),

    # ───────────────────────────── STUDIO ─────────────────────────────
    P("STU-1", "studio", src=["STU-1"],
      title="Studio models + store (pocketdj-studio.json v1 over VersionedJsonWriter) + folders (SAF roots) + reconcile",
      files=m("studio/model/StudioModels.kt", "studio/model/StudioFactory.kt", "studio/model/StudioSourceSerializer.kt", "studio/store/StudioStore.kt", "studio/store/StudioFolders.kt", "studio/store/StudioReconcile.kt", "di/StudioGraph.kt")
            + [TR + "studio/ios-studio-v1.json"] + t("studio/model/StudioModelsCodecTest.kt", "studio/store/StudioStoreTest.kt", "studio/store/StudioReconcileTest.kt"),
      deps=["SURF-1", "COL-2"], est=2200, prio="P0", rank=5),

    P("STU-2", "studio", src=["STU-2"],
      title="Studio native DSP lib (cpp/pdjdsp: TinySoundFont, Signalsmith Stretch, TrackFX/MasterFX kernels, mixer) + OboeSink implementing the shared AudioSink + StudioRender/RenderGraph + NDK Gradle wiring",
      goal=("Decision D1's Studio half, built on MIX-2's shared `audio/core`: one NDK module (CMake, C++17) with a thin JNI surface — `sf2_voice.cpp` (tsf.h), `stretch.cpp` (Signalsmith, OFFLINE time/pitch), `fx_kernels.cpp` (TrackFX/MasterFX ports), `mixer.cpp`, "
            "`oboe_sink.cpp` + `audio/core/OboeSink.kt` (an `AudioSink` implementation with Oboe data callback; device default for Studio, emulator uses AudioTrackSink); `StudioRender` (carve, import, loop render with exact frames + priming trim, sample render with FX tail drain, "
            "stretch/transform via the native stretcher, mixPCM) on a single-permit Mutex; `RenderGraph` pull API; Kotlin kernel mirrors for JVM tests; Gradle externalNativeBuild + Oboe prefab + abiFilters."),
      files=[CPP + "CMakeLists.txt", CPP + "jni.cpp", CPP + "mixer.cpp", CPP + "fx_kernels.cpp", CPP + "sf2_voice.cpp", CPP + "stretch.cpp", CPP + "oboe_sink.cpp", CPP + "third_party/tsf.h", CPP + "third_party/signalsmith-stretch.h"]
            + m("audio/core/OboeSink.kt", "studio/audio/StudioAudio.kt", "studio/audio/StudioRender.kt", "studio/audio/RenderGraph.kt", "studio/audio/NativeDsp.kt", "studio/dsp/TrackFxKernel.kt", "studio/dsp/MasterFxKernel.kt")
            + [GRADLE, TOML] + t("studio/audio/StudioRenderTest.kt", "studio/dsp/KernelsTest.kt", "studio/audio/StudioAudioTest.kt"),
      deps=["STU-1", "MIX-2", "MIX-3"], est=2300, prio="P0", rank=13,
      device="Oboe low-latency path, real latency numbers, route-change (headphones) stream rebuild."),

    P("STU-3", "studio", src=["STU-3"],
      title="Producer shell + Samples tab (mic, import, from-track via LocalAudioCache→BurnStore) + sample editor + mixer deck + StudioEngine",
      files=m("screens/producer/ProducerScreen.kt", "screens/producer/StudioSubTab.kt", "screens/producer/ProducerRoutes.kt", "screens/producer/samples/SamplesScreen.kt", "screens/producer/samples/SampleEditorSheet.kt", "screens/producer/samples/NewSampleFromTrackSheet.kt",
              "screens/producer/samples/MicRecordSheet.kt", "screens/producer/common/MixerDeck.kt", "screens/producer/common/WaveformView.kt", "screens/producer/common/EditSlider.kt", "screens/producer/common/FolderRows.kt",
              "studio/engine/StudioEngine.kt", "studio/engine/MicRecorder.kt", "studio/engine/AudioFocusPolicy.kt", "studio/audio/LocalAudioCache.kt", "studio/demux/BeatDetect.kt", "studio/demux/BeatMath.kt", "studio/StudioSettings.kt", "di/StudioGraph.kt")
            + t("studio/engine/StudioEngineTest.kt", "studio/audio/LocalAudioCacheTest.kt", "studio/demux/BeatDetectTest.kt"),
      deps=["STU-1", "STU-2", "SVC-2"], est=2500, prio="P0", rank=19),

    P("STU-4", "studio", src=["STU-4"],
      title="Loops tab + slice editor (performance pads)",
      files=m("screens/producer/loops/LoopsScreen.kt", "screens/producer/loops/LoopSliceSheet.kt", "screens/producer/samples/SliceEditorSheet.kt", "studio/engine/LoopAudition.kt") + t("studio/engine/LoopAuditionTest.kt", "studio/engine/SliceMathTest.kt"),
      deps=["STU-3"], est=1400, prio="P0", rank=25),

    P("STU-5", "studio", src=["STU-5"],
      title="Sequencer tab + pattern engine (clock, step modes, per-step loop/stretch) + bounce",
      files=m("screens/producer/sequencer/SequencerScreen.kt", "screens/producer/sequencer/PatternEditor.kt", "screens/producer/sequencer/PatternRowCard.kt", "studio/engine/PatternEngine.kt", "studio/engine/PatternClock.kt", "studio/engine/PatternMath.kt", "studio/engine/PatternBouncer.kt")
            + t("studio/engine/PatternEngineTest.kt", "studio/engine/PatternClockTest.kt", "studio/engine/PatternMathTest.kt", "studio/engine/PatternBouncerTest.kt"),
      deps=["STU-3", "STU-4"], est=2500, prio="P0", rank=29),

    P("STU-6", "studio", src=["STU-6"],
      title="Cues tab + cue-seek playback plumbing (sequencer seek) + CuePointsProvider for the Mix deck cue-jump row",
      files=m("screens/producer/cues/CuesScreen.kt", "screens/producer/cues/CueTimeline.kt", "studio/cues/CueSeek.kt", "studio/cues/StudioCuePointsProvider.kt", "di/StudioGraph.kt") + t("studio/cues/CueSeekTest.kt", "studio/cues/CuePointsProviderTest.kt"),
      deps=["STU-1", "PB-1", "MIX-13"], est=1200, prio="P0", rank=27),

    P("STU-7", "studio", src=["STU-7"],
      title="Collections integration: StudioRowResolver (play studio ids as local files), counts, realize synthetic entries, Storage rows",
      files=m("studio/StudioPlayback.kt", "studio/StudioRowResolver.kt", "studio/StudioAnalyzer.kt", "screens/settings/sections/StudioStorageSection.kt", "data/collections/CollectionCatalog.kt", "data/collections/RealizeEngine.kt",
              "data/storage/StorageService.kt", "di/StudioGraph.kt")
            + t("studio/StudioRowResolverTest.kt", "data/collections/RealizeStudioEntriesTest.kt"),
      shared=[M + "data/collections/CollectionCatalog.kt, data/collections/RealizeEngine.kt (studio kinds)", M + "data/storage/StorageService.kt (STUDIO categories)"],
      deps=["STU-1", "STU-5", "PB-1", "COL-4"], est=1300, prio="P0", rank=33),

    P("STU-8", "studio", src=["INST-1"],
      title="Instrument packs + SF2 synth engine (native) + on-screen keys + takes (click/count-in)",
      files=m("studio/packs/InstrumentPackStore.kt", "studio/packs/InstrumentPackModels.kt", "studio/engine/InstrumentEngine.kt", "studio/engine/InstrumentEventLog.kt", "studio/engine/ClickTrack.kt", "screens/producer/instruments/InstrumentsScreen.kt",
              "screens/producer/instruments/PianoKeyboard.kt", "screens/producer/instruments/PacksSection.kt", "screens/producer/instruments/TakesScreen.kt", "data/config/Endpoints.kt")
            + t("studio/packs/InstrumentPackStoreTest.kt", "studio/engine/InstrumentEventLogTest.kt", "studio/engine/ClickTrackTest.kt"),
      shared=[M + "data/config/Endpoints.kt (instrument packs base)"],
      deps=["STU-2", "STU-3"], est=2500, prio="P1", rank=36),

    P("STU-9", "studio", src=["INST-2"],
      title="Score: quantizer, layout, editor (Enter/Select/Move/Edit, undo/cancel), live staff, PDF + MIDI + audio export",
      files=m("studio/score/ScoreQuantizer.kt", "studio/score/ScoreLayout.kt", "studio/score/ScorePlayhead.kt", "studio/score/ScorePdf.kt", "studio/midi/SmfWriter.kt", "studio/midi/SmfParser.kt", "studio/midi/MidiImport.kt",
              "screens/producer/instruments/ScoreEditor.kt", "screens/producer/instruments/ScoreScreen.kt", "screens/producer/instruments/LiveStaff.kt")
            + t("studio/score/ScoreQuantizerTest.kt", "studio/score/ScoreLayoutTest.kt", "studio/midi/SmfRoundTripTest.kt"),
      deps=["STU-8"], est=2500, prio="P1", rank=43),

    P("STU-10", "studio", src=["INST-3"],
      title="MIDI input (USB + BLE via MidiManager) + arpeggiator + overdub staffs",
      files=m("studio/midi/MidiInput.kt", "studio/midi/MidiParser.kt", "studio/midi/BleMidiScanner.kt", "studio/midi/MidiSettings.kt", "studio/engine/ArpeggiatorEngine.kt", "studio/engine/OverdubController.kt",
              "screens/producer/instruments/ArpPanel.kt", "screens/producer/instruments/OverdubControls.kt", "screens/producer/instruments/BluetoothMidiSheet.kt")
            + t("studio/midi/MidiParserTest.kt", "studio/engine/ArpeggiatorEngineTest.kt", "studio/engine/OverdubInvariantTest.kt"),
      deps=["STU-9"], est=2200, prio="P1", rank=51,
      device="USB/BLE MIDI hardware."),

    P("STU-11", "studio", src=["TRK-1"],
      title="Tracks arranger: model CRUD, home list + folders, lanes/clips UI, clip baker, artifacts browser",
      files=m("studio/store/StudioStoreArranger.kt", "studio/engine/ArrangerClipBaker.kt", "screens/producer/tracks/TracksHomeScreen.kt", "screens/producer/tracks/ArrangementScreen.kt", "screens/producer/tracks/LaneRow.kt",
              "screens/producer/tracks/BeatRuler.kt", "screens/producer/tracks/ClipPickerSheet.kt", "screens/producer/tracks/TrackEditSheet.kt", "screens/producer/tracks/ArtifactsSection.kt")
            + t("studio/store/StudioStoreArrangerTest.kt", "studio/engine/ArrangerClipBakerTest.kt"),
      deps=["STU-1", "STU-3"], est=2500, prio="P1", rank=36),

    P("STU-12", "studio", src=["TRK-2"],
      title="MultitrackPlayer (single render callback: clip sum + per-track gain/pan + TrackFX + MasterFX), live mix, master FX grid, looper, seek",
      files=m("studio/engine/MultitrackPlayer.kt", "studio/engine/MultitrackRenderContext.kt", "studio/engine/MultitrackClock.kt", "screens/producer/tracks/TransportBar.kt", "screens/producer/tracks/MasterFxGrid.kt", "screens/producer/tracks/LoopRegionOverlay.kt")
            + [CPP + "multitrack.cpp"] + t("studio/engine/MultitrackPlayerTest.kt", "studio/engine/MultitrackClockTest.kt"),
      deps=["STU-11", "STU-2"], est=2200, prio="P1", rank=44),

    P("STU-13", "studio", src=["TRK-3"],
      title="Bounce (artifact), record-to-master (Clean/Quantized), scissor trim (multi-select), Beat Match + grid analyzer, channel-strip bake",
      files=m("studio/engine/ArrangerBouncer.kt", "studio/engine/ArrangerBeatMatch.kt", "studio/engine/ArrangerGridAnalyzer.kt", "studio/engine/MasterRecorder.kt", "studio/store/TrimGap.kt",
              "screens/producer/tracks/TrimModeOverlay.kt", "screens/producer/tracks/BounceSheet.kt", "screens/producer/tracks/RecordMenu.kt")
            + t("studio/engine/ArrangerBeatMatchTest.kt", "studio/engine/ArrangerGridAnalyzerTest.kt", "studio/store/TrimGapTest.kt", "studio/engine/ArrangerBouncerTest.kt"),
      deps=["STU-12"], est=2400, prio="P1", rank=52),

    P("STU-14", "studio", src=["DMX-1"],
      title="Demuxer core: sources + DemuxStore + chord detection + timeline + chord detail + stems (download via SVC-11, synced 4-stem playback via VoiceGroup, mute/solo)",
      files=m("studio/demux/DemuxModels.kt", "studio/demux/DemuxStore.kt", "studio/demux/ChordDetector.kt", "studio/demux/Chromagram.kt", "studio/demux/StemPlayer.kt", "screens/producer/demux/DemuxScreen.kt",
              "screens/producer/demux/DemuxSourcePicker.kt", "screens/producer/demux/DemuxTimeline.kt", "screens/producer/demux/ChordDetailSheet.kt", "screens/producer/demux/StemsSection.kt", "di/StudioGraph.kt")
            + t("studio/demux/ChordDetectorTest.kt", "studio/demux/ChromagramTest.kt", "studio/demux/DemuxStoreTest.kt", "studio/demux/StemPlayerSyncTest.kt"),
      deps=["STU-3", "MIX-2", "SVC-11"], est=2300, prio="P1", rank=40),

    P("STU-15", "studio", src=["DMX-2"],
      title="Demux drum pattern + melody + key + instrumental + cut sample + send stems to arrangement + lyrics sidecar panel",
      files=m("studio/demux/DrumPatternDetector.kt", "studio/demux/MelodyTracker.kt", "studio/demux/KeyDetector.kt", "studio/demux/DemuxInstrumental.kt", "studio/demux/LyricsSidecar.kt", "screens/producer/demux/DrumPatternPanel.kt",
              "screens/producer/demux/InstrumentalPanel.kt", "screens/producer/demux/CutSampleSheet.kt", "screens/producer/demux/LyricsPanel.kt")
            + t("studio/demux/DrumPatternDetectorTest.kt", "studio/demux/MelodyTrackerTest.kt", "studio/demux/KeyDetectorTest.kt"),
      deps=["STU-14", "STU-5", "STU-8", "STU-11"], est=2500, prio="P2", rank=66),

    P("STU-16", "studio", src=["STU-8"],
      title="Studio hardening + diagnostics + emulator seed + docs sync + single-audio-layer grep guard",
      files=m("studio/StudioSeed.kt") + ["android/app/src/main/assets/studio-fixture-tone.m4a", A + "studio/ProducerSmokeTest.kt", "android/specs/studio.md", ARCH_DOC]
            + t("studio/SingleAudioLayerGuardTest.kt"),
      shared=[ARCH_DOC],
      deps=["STU-7", "STU-10", "STU-13", "STU-15"], est=900, prio="P1", rank=96,
      acc=["SingleAudioLayerGuardTest fails if any class outside audio/core creates an AudioTrack, MediaCodec audio decoder or OfflineRenderer"]),
]
