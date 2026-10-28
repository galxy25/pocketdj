state: reviewed

# MIX-10 Streaming decks in the engine

- [x] StreamDecks.kt: StreamRules (pure: runway 2 s start / 4 s resume, 1 s/15 s append chunk, hold condition, strict readiness), StreamHandle/StreamLoaderPort/StreamSourceFactory seams, StreamDecks (loadStreaming, pumpStream, attach, finishStream, handleStreamFailure, clearStream, holdStream, tick/seek/transport hooks, MainVoiceStatus for the stem machine, buffering/streaming StateFlows, streamingSongIds, autoUpcomingSongIds, deckReadyToAir/deckCanAir/songOnDevice/transientlyUnloadable, heldSinceMs stall clock), production adapters (LoaderStreamHandle, MixStreamLoaderPort, Mp3StreamSourceFactory)
- [x] di/MixGraph.kt: `mixStreamDecks`; `loader.onProgress` -> pump, `loader.pinnedIds` -> streamingSongIds, `upcomingProvider` -> autoMixHost
- [x] Tests: StreamDecksTest (36)

## Tests
JVM suite 2479 tests, 0 failures (+36 StreamDecksTest); `assembleDebug` green.

## Touched outside owned files (all additive)
- mix/engine/DeckController.kt: `open(..., final = true)` param and `growTo(frame, final)`.
- mix/engine/MixEngine.kt: `reportDeckEnded`/`ejectDeckCore` now `internal`; `beginStreamLoad`/`commitStreamLoad`; `seek`/`restart` accept a held deck that has no voice yet (and restart on a held deck fires `onSeeked` so the pump re-checks 0:00).
- mix/engine/StemController.kt: `mainStreamDied(deck)` (clears a TO_FULL_MIX handover, runs settleDeadSources).
- di/MixGraph.kt (owned area, wiring).

## Deviations / notes
- No segment chaining / re-open of the file: the one growing `Mp3Decoder` runs on into the adopted file (`markComplete` + final window), so completion is seamless by construction (test: one open, zero re-seeks across appends). Stem stream pump itself (re-open, lockstep window, slowest-part frontier, finishStemStream) was already built in MIX-8 StemController; this package supplies its `MainVoiceStatus` (`stems.main`), `onMainProgressed`, `onUnhold` and the failure hand-off.
- The voice's window end is the schedulable frontier (iOS `endFrames`); a hold pauses the voice, a resume re-seeks it to the held position.
- Existing engine hooks (onDeckTick/onSeeked/onTransport/onStemsReset) are CHAINED, not replaced. `engine.streamHeldProvider` is assigned (stem hold has its own seam).
- Auto-DJ facts are behind `StreamDecks.autoHooks: AutoStreamHooks` (isLiveDeck / isTransitioning / skipToNext) and `upcomingProvider`; MIX-9 (or the integrator) must assign `autoHooks`. `restampAutoEnd` = `engine.autoDj.onSeek(deck)` (the Auto-DJ re-times from engine duration; MIX-9 must also refresh its per-deck duration from `engine.duration` there, as iOS `autoDeckDurationMs`).
- Stall clock: `heldSinceMs(deck)` (for MIX-9's `autoStallSkipSeconds` = `StreamRules.AUTO_STALL_SKIP_SECONDS`), set when the hold begins.
- Loop-on-a-stream: a loop on a streaming voice is not re-armed on resume (Voice.seek keeps its plan); untested beyond MIX-8.
- Not done: emulator steps (no emulator). `restorePersisted` of a streaming deck is not special-cased (a not-on-disk restore goes through `streamLoad`).

## Device-only
Real Mp3Decoder over a growing file (`totalFrames` claim from the Xing header, `Mp3StreamSourceFactory` retry until the header is readable), network throttling holds/resumes, cellular dead-zone, files appearing under files/burns after adoption.

## Questions for Levi
- None.

## Review
fixes applied
- MAJOR stall clock: fixed. `heldSinceMs` is stamped only while held AND playing (setHolding, onTransport(playing=true)); cleared on pause/unhold/clearStream. Test `theStallClockStartsWhenAHeldDeckStartsPLAYINGNotWhenItWasHeld`.
- MINOR frontier from bytes only: fixed. Frontier is capped by `source.availableFrames`. Test `theFrontierNeverOutrunsWhatTheDecoderCanProduce`.
- MINOR failure paths: fixed. Stems-carried path ends the main voice at its frontier (`growTo(endFrame, final=true)`); both failure paths call `sources.markComplete`. Test `aStreamFailureDrainsTheDecoderSoTheTruncatedEndIsReachable`.
- MINOR Buffering badge on stem hold: fixed. New `StemController.onHold` callback (fired at both hold sites) republishes.
- MINOR circular upcoming wiring: fixed. Removed `StreamDecks.upcomingProvider`/`autoUpcomingSongIds`; `EngineAutoMixHost.upcomingProvider` is the single source that MIX-9 assigns (the downloader reads the host). Removed the obsolete StreamDecks test; downloader ordering stays covered by CollectionMixDownloaderTest.
- MINOR untagged CBR: fixed. `Mp3Decoder(expectedBytes)` + `Mp3FrameReader.estimateTotalFrames` give a partial untagged file an estimated length (exact once complete).
- NIT: `streamingSongIds` is now a @Volatile snapshot. onTick/MixTick double-handling left as is (the tick order is owned by the engine; very narrow window).
