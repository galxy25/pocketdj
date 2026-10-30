state: reviewed

# ANS-GAP-1 - Jukebox AM catalog match stage + onStart bootstrap (SURF-10 / SURF-2)

- [x] JukeboxAppleMusicMatch: JukeboxExternalMatch over AppleMusicApi.searchCatalog (dev token; storefront from userStorefront else "us"); term = title or "title artist" (iOS); top hit maps back to an indexed song (AppleMusicRecognition.indexSong) else an ad-hoc `amrec_<storeId>` IndexSong
- [x] JukeboxAmPlacementSink: AM-only rows wait (bounded 15 min) for the rip, then the repository's normal placement runs; timeout throws -> transient hint
- [x] Repository: AM-only match shows as playable (accept requests the rip via new adHocRipStarter seam, before both the Mix and sequencer paths); no rip server -> hint, nothing queued
- [x] JukeboxGraph wires externalMatch / placementSink / adHocRipStarter (BrowseGraph.appleMusicRecognition.startRipAndBurn)
- [x] SURF-2 onStart bootstrap: already wired (AppGraph init launches JukeboxGraph.repository.bootstrap() at app start; verified, no change needed)
- [x] JukeboxAppleMusicMatchTest: 9 tests (MockWebServer), all pass; full suite 5420 tests, 0 failures; assembleDebug green

## Deviations
- Android has no MusicKit stream, so iOS's `am:<id>` sequencer row is replaced by rip-then-queue (amrec_ id, same as the recognizer flow).
- No foundation-model pick stage (unchanged from P1 cut).
- Build needed -Dorg.gradle.jvmargs=-Xmx3g -Pkotlin.daemon.jvmargs=-Xmx3g (compiler OOM at 2g with parallel packages); gradle.properties untouched.

## Questions for Levi
- None.

## Review
fixes applied

- MINOR JukeboxRepository mixOwns checked once before the rip wait -> fixed: `route()` re-checks the session id and the Mix after the sink returns (AM-only rows); a mix started mid-rip takes the placement (parked behind a burn), the sequencer never sounds over it. Test: mixStartedDuringTheRipWaitTakesThePlacementNotTheSequencer.
- MINOR AM-only match looks like a ripped hit -> fixed: `Match.Found.isAdHoc`; JukeboxScreen appends " (Apple Music — rips on accept)"; a "Ripping “X” ..." hint shows once the rip starts.
- MINOR no repository tests -> fixed: JukeboxRepositoryAdHocRipTest (4 tests: flag, no rip server keeps row + posts nothing + queues nothing, places only after the rip lands, mix-during-wait). New `ripPlayable` constructor seam. Suite 5420 -> 5424, 0 failures; assembleDebug green.
- MINOR request lost when the rip can't start -> fixed: the rip kick now runs BEFORE the row is consumed / the decision POSTed; failure leaves the row in the inbox (retryable). Sink timeout message is now surfaced instead of "isn't playable anymore". (Disabling buttons up front when no rip server exists not done; the retry-safe path covers it.)
- MINOR capture-on-accept diverges from iOS -> NOT changed, open question below (a product decision; behaviour matches the roadmap's "AM row / rip").
- NIT storefront cache -> fixed: AtomicReference; fallback "us" deliberately not cached (account may link later).
- NIT status file -> noted: the emulator step (pdj.amApiBase mock) was NOT run (shared emulator is the integrator's); the pre-change count was taken from the prior status (5420).

## Questions for Levi
- Is capture-on-accept OK for the sequencer path (no Mix running)? iOS streams AM rows through MusicKit and captures nothing; Android rips + burns every accepted non-library request. Options: keep, Mix-only, or a setting.
