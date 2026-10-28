state: implemented

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
