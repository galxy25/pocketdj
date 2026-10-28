state: merged

# SVC-1 Rip client parity

- [x] RipsModels: stems/stemVersion/stemFormat/beatgrid/firstBeat/firstDownbeat/beatGridBpm/beatsPerBar/tempoConfidence/steady/cutKey/lyrics + stemUrls()/beatgridKey/lyricsKey; batch + cancel models
- [x] RipServerClient: presign, awaitReadyInteractive (20 s wall-clock -> StillRipping), ripCollection (+404 fallback), cancelRips; old 30-min awaitReady removed
- [x] PresignCache (5 h usable / 6 h TTL, in-flight dedup, prefetch), RipJobTracker (pollToReady 2 s, 1 h cap, ignores error, onRipReady), RipSettings
- [x] RipsRepository generation guard + publish-only-on-change
- [x] PlaybackController: StillRipping path, presigned URL on manifest hits (single + queue) when a server is configured
- [x] Tests: 31 new (839 total JVM tests, 0 failures); assembleDebug green

## Deviations / files outside owned set
- di/AppGraph.kt: additive presignCache + ripJobTracker lazies and two PlaybackController args (controller is built there; ServicesGraph exposes them).
- StillRipping surfaces via PlaybackController.lastError ("Still ripping - ...") rather than a new PlayOutcome subtype, to avoid breaking exhaustive `when`s in browse screens; PlayOutcome.Preparing is still returned immediately (wait runs in background scope).
- Partial `stems` objects decode tolerantly (all-default) and just yield no URLs.
- ripFromCloud flag not ported (no Android setting). pdj_ ids fenced in batch rip.
- Prefetch of next-queue presigns is implicit: whole album queue is presigned at queue build (deduped, 6 h TTL); PresignCache.prefetch is available for PB-1.

## Questions for Levi
- None.

## Review
fixes applied (JVM tests 839 -> 852, 0 failures; assembleDebug green)

- MAJOR album-queue presign: FIXED. Only the start item is presigned before play; next 3 are prefetched non-blocking (PlaybackUrlResolver) and swapped in via refreshAhead() on every item transition; onPlayerError re-mints once per song (PresignCache.invalidate) for expired/403 URLs. Tests: PlaybackUrlResolverTest (configured/unconfigured/failure/non-blocking prefetch/ahead window).
- MINOR background wait hijack: FIXED. playGeneration bumped on play() entry and every queue commit; RipPlayWait.run takes an isCurrent guard (Superseded = refresh manifest only). Test: RipPlayWaitTest.readyAfterUserPlayedSomethingElse.
- MINOR ripCollection/cancelRips side effects: FIXED. New RipCollectionCoordinator (markUserRequested, adopt + poll queued/inflight; cancel -> RipJobTracker.cancel drops polls/rows/protection). Tests: RipCollectionCoordinatorTest. Still needs wiring by the first collection-RIP caller (no caller exists yet).
- MINOR PlaybackController tests: FIXED via extraction (controller needs Context/MediaController, not JVM-constructible): URL policy in PlaybackUrlResolver, StillRipping/tracker handoff in RipPlayWait; both tested with fake presigner/tracker.
- MINOR docs ledger: FIXED. SVC-1 row set to PARTIAL (emulator steps not run).
- MINOR PresignCache cancellation: FIXED. Mint runs in the cache scope (async LAZY, shared); a cancelled caller no longer completes waiters with null. Tests: cancelledCaller_doesNotHandOtherWaitersNull, invalidate.
- NIT RipsRepository.persist ordering: FIXED (Mutex + skip when generation moved on).
- NIT AppGraph.kt outside owned files: ACKNOWLEDGED, not changed; merge plan: PB-1 must keep presignCache/ripJobTracker args in the PlaybackController(...) call when resolving the conflict.
