state: reviewed

# MIX-8 Loop (infinity) + stem decks + zero-dead-air handover + beat-grid hydrate

- [x] Additive engine seams: MixEngine hooks `onSeeked` / `onDeckTick` / `onTransport` / `onDeckLoaded`; MixTick calls `onDeckTick`; DeckController owns the 4-voice stem group (install/remove, play/pause/seek/trueSeconds route to stems when the graph intent is stems, `setLoopSeconds`)
- [x] LoopController.kt: `LoopMath` (pure: usesBeats, median unitSeconds, windowMath, clampWindow slide-back, bounds via BeatMath, nudge 1..32, schedulable) + `LoopController` (setLoop commit-on-success, setLoopUnits, nudgeLoop, seek-while-looped re-anchor, release via engine seek so Auto-DJ end re-times, reresolve after async grid, restore)
- [x] StemController.kt: `StemRules` (handoverReady, underrun decision tables, deadSourceEnd, balance), `ShiftedSource`, `StemProvider`/`StemStream` seams + `BurnStemProvider` (BurnStore + MixStreamLoader), `StemController` (intent + stemIntentGen, deferSourceUntilPlay, requestStemSource wire-local/stream/fetch, advance decision machine, cutToStems/cutToFullMix via graph `crossfadeTo`, settleStemFade, checkFade land/abort, stemUnderrun/mainUnderrun/settleDeadSources, mute/vol -> stem balance, `handovers` StateFlow for "Loading stems..."), `MixDeckExtras` (builds + installs all hooks)
- [x] BeatGridHydrator.kt: local sidecar sync, download only when pulse on or forced (loop), songId-guarded patch, `onHydrated` re-resolves a loop
- [x] di/MixGraph.kt: `mixDeckExtras` built with the engine; stem stream fan-in via `addStemListener`
- [x] Tests: StemHandoverTest (25), LoopWindowTest (16), BeatGridHydratorTest (9) + StemRig test support

## Tests
JVM suite 2189 -> 2239 (+50), 0 failures; `assembleDebug` green.

## Touched outside owned files (all additive)
- mix/engine/MixEngine.kt: 4 hook vars (`onSeeked`, `onDeckTick`, `onTransport`, `onDeckLoaded`) + their call sites (seek, setPlaying transition, commitLoad).
- mix/engine/MixTick.kt: `e.onDeckTick` call after the playhead advances (also in the loop-fold branch).
- mix/engine/DeckController.kt: stem group + routing described above (transport for a stems-carried deck had to live next to the voice).
- di/MixGraph.kt: `deckExtras` / `mixDeckExtras` wiring + stem listener.

## Deviations / notes
- No segment queue: iOS queues 3 loop passes on the node and tops up on the tick; here the window lives ON the Voice (decoder wraps frame-exactly, position counter folds identically), so no top-up / timeline-reset guard exists. `armLoop` still proves the window schedulable before touching a voice, and loopOn commits only on success.
- Stem voices are wrapped in `ShiftedSource` so they live in the MAIN voice's file-frame domain (analog album-side offset). The graph's handover (seek incoming to outgoing frame, 1-frame alignment check) then needs no offset knowledge. Stem frame == song frame; no mp3 priming handling (the Android decoder applies the untagged 576 priming itself).
- Growing stems need no re-open dance: one `Mp3Decoder(complete=false)` per part; the pump just raises all four Voice windows (`append`) to the slowest part's frontier in lockstep. `MonotonicByteSource` keeps a stream part's length from shrinking when the loader MOVES the file into the burn folder under an open reader.
- A loop does NOT force an outright (non-crossfaded) switch on a stem handover like iOS (iOS cannot crossfade a queue); the loop is applied to the incoming voices first and the graph crossfade proceeds. A misaligned fade aborts via the graph and retries on the next tick.
- Hold/Buffering for stems is a flag (`isHeld`) OR-ed into `engine.streamHeldProvider` (wraps any earlier provider). The full mix as a growing stream (truncation, `canGrow`) arrives through the `MainVoiceStatus` seam (default `CompleteFileMain`): MIX-10 must set `stems.main`, call `stems.onMainProgressed(deck)` on main-stream progress and clear its own hold through `stems.onUnhold`.
- Profile-source ("Pocket DJ") app-managed stems (`profileStemResolve`) are not wired: no Android profile source exists yet; extend `StemProvider.local`.
- Roadmap unit_tests names (LoopControllerTest / StemControllerTest) are covered inside the owned test files LoopWindowTest / StemHandoverTest.
- Stem streaming against the real MixStreamLoader (Mp3Decoder over a file still being written) is JVM-tested through fakes only; the decoder/stream pair is device-verified territory.
- Not done: emulator steps (no emulator per instructions); ledger row in docs/ARCHITECTURE-ANDROID.md (integrator).

## Device-only
Hearing the handover seam and loop click-freeness; real Mp3Decoder over a growing stem file; logcat `mixstems` / `beatgrid hydrate` lines on the emulator.

## Questions for Levi
- None.

## Review
Fixes applied.
- MAJOR MixPersistence saves committed stemMode -> fixed: `engine.stemModeOnProvider` (= `stems::modeOn`) feeds `MixPersistence.deckSnapshot(stemIntent)`, as iOS `stemModeOn`. Test `theDurableSnapshotSavesTheStemIntentNotTheCommittedFlag`.
- MINOR audibility predicate mismatch -> fixed: `MixGraph.crossfadeTo(forceOutright)`; StemController passes `!audible`, so graph and controller never disagree. Test `aHeldDeckSwitchesOutrightEvenWhileItsMainVoiceReportsPlaying`.
- MINOR streamHeldProvider overwrite -> fixed: separate `engine.stemHeldProvider` OR-ed in `MixEngine.streamHeld`; StemController reads `streamHeldProvider` lazily. MIX-10 may assign `streamHeldProvider` in any order. Test `aStemHoldSurvivesMix10ReassigningTheStreamHoldProvider`.
- MINOR main-thread stem open -> fixed (mitigated): `StemProvider.prewarm` opens+measures the four stems on IO at deck load / stem-mode restore; `BurnStemProvider.local` on main consumes the warmed parts (cold path unchanged as fallback). `localBeatGrid` (small sidecar JSON read) still runs on main in the hydrator; not moved.
- MINOR status/ledger -> partly: status set to reviewed. Emulator steps not run (no emulator per instructions); ledger row in docs/ARCHITECTURE-ANDROID.md left to the integrator: PARTIAL (device-only handover seam, loop click-freeness, growing-file Mp3Decoder; UI wiring pending MIX-13/14).
- NIT per-tick pump / unused `runner` -> not changed (runner kept for API stability; pump in stemUnderrun is guarded by active()).
