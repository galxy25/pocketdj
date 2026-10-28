state: merged

# SVC-11 Cloud stems client + burned stems pull + Stemify on burn bar

- [x] data/stems/StemClient.kt: StemPhase/StemJob/batch models + pure rules (fence, 3-layer idempotence, labels, summaries)
- [x] RipServerClient: requestStemify, stemJob, stemifyCollection (+404/transport per-song fallback, over-cap needsConfirm)
- [x] RipJobTracker: stemJobs, stemify, pollStemReady (3 s, 4 h cap; stops ready/error/ineligible), pruneFinishedStemJobs, cancelStems
- [x] burns/BurnStems.kt pure stem/beat-grid file rules; BurnStore uses it (burn pull, validation, aux removal already present from SVC-2)
- [x] CollectionBurnBar: Stemify button, STEM op, progress poll, over-cap confirm dialog, row note "Queued…/Ripping first…/Stemming…"
- [x] Tests: StemClientTest, StemJobsTrackerTest, BurnStemsTest (15 new); full suite 1910 tests, 0 failures

## Touched outside owned files
- di/AppGraph.kt: wired stem lambdas into RipJobTracker (additive).

## Deviations
- iOS `ripFromCloud` flag omitted (no Android setting exists).
- stemifyCustom (/stemify-custom upload) not ported: belongs to the Demuxer/Studio packages.

## Questions for Levi
- none

## Review
- MAJOR BurnStemsTest rewrite -> fixed: SVC-2 BurnStemsTest restored verbatim; pure-helper tests moved to BurnStemsRulesTest.
- MAJOR Stop lacked /stemify-cancel -> fixed: RipServerClient.cancelStemCollection (404 silent), called from controller stop(); tests added.
- MAJOR per-song pollStemReady storm -> fixed: batch path only seeds queued rows; manifest poll drives completion; pruneFinishedStemJobs after each manifest refresh.
- MAJOR ledger row Planned -> fixed: PARTIAL, emulator steps noted unverified.
- MINOR Stop during enqueue -> fixed: enqueue Job cancelled in stop()/dispose; test added.
- MINOR stem poll cadence -> fixed: STEM_POLL_INTERVAL_MS=5000 x STEM_POLL_MAX_TICKS=2880; test added.
- MINOR seed on fallback -> fixed: BatchStemResult.viaBatch, seed only then and never over an existing entry.
- MINOR BurnStems helpers unused -> fixed: BurnStore.localStemSongIds and sweepAuxFiles now use fullyStemmedIds/auxToSweep.
- MINOR row recomposition -> fixed: rememberRowNote collects the manifest flow. Stemmed accent tint: rejected, iOS CollectionSongRow has no stemmed row tint (only a stem glyph); note-clear is what iOS does.

fixes applied. Tests: 1926 run, 0 failures.
