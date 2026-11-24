state: merged

# P2-REM-11 Mix Together core (pure)

- [x] MixSyncModels.kt: mix.* kinds, MixSyncAnchor/Event/EventMessage/DeckState/Snapshot/Ready/Beat/Handover/Reject/Request (iOS field names; deck = Deck.label "A"/"B"), MixSyncModel (pure apply), MixSyncTunables
- [x] MixSyncCore.kt: host ordering, proposals, no-echo + pending shadowing (2 s expiry -> snapshot request), coalescing (50 ms / 250 ms seeks, trailing send via tick/flushOutbox), gap > 1.5 s snapshot request, retries 3/6/12/24/48 s then stop, buffer cap 512, ownership (host A, first caps:mix joiner B, claim/release as proposals), host hold-until-ready (4 s timeout), takeOver + handover (a live mix is never ended by an empty/older host), beats folded into mirror
- [x] RemoteControllerMixSession adapter: registers handlers/activity probe/"mix" cap on RemoteSessionController
- [x] MixSyncCoreTest (59 tests incl. wire-shape/model cases) over an in-memory FIFO net with per-device clock skew

Tests: MixSyncCoreTest 59; full suite green, assembleDebug green. Manifest/gradle/proguard untouched (no assembleRelease needed).

## Deviations / notes
- Engine seams (gestureTap causes, systemHeld/rejoin, drift correction, syncPlay, reconcile, ready reporting, 2 s beat sender loop) are NOT here: core exposes MixSyncSink hooks (onApply, onSnapshotAdopted, onRepair, onBeat, localDeckReady, seedEvents, scheduleFlush) for P2-REM-12/13.
- The "Deck A belongs to You." wording when the host is the owner mirrors iOS name(of:) quirk; REM-12/13 may improve.
- Tests use a FIFO in-memory net rather than LoopbackHub (needs controller attach); wire envelopes are real base64 RemoteEnvelopes.
- one-at-a-time.sh refused --no-quiesce-fin (LM Studio models loaded), so ran with default quiesce.
- Disk filled mid-run: removed build dirs of merged packages' worktrees; killed two hung gradle clients of P2-POC-12 (0% CPU for 30-60 min).

## Questions for Levi
- None.

## Review
- MINOR snapshot ladder (gap branch ignored the 5-attempt cap) -> fixed: gap request skipped once attempts >= SNAPSHOT_MAX_ATTEMPTS while awaiting; test gapPathStopsAfterFiveSnapshotRequestsToo.
- MINOR no readiness hook -> fixed: MixSyncSink.onMirrorChanged(deck, kind) fires from applyOrdered for every ordered LOAD/EJECT (own echo and pending-shadowed included, host included); test mirrorChangedFiresForOwnEchoLoadAndEject.
- NIT peerReadiness mutable -> fixed: exposed as read-only Map; single-thread (Main) requirement documented on the sink hook.
- NIT loopback / install() untested -> rejected for now: setup is not cheap; deviation stays recorded, P2-REM-12 must exercise install().

Tests: MixSyncCoreTest 59 -> 61; full suite green (7517 total), assembleDebug green.

fixes applied
