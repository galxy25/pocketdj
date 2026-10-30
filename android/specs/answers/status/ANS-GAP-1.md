state: implemented

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
