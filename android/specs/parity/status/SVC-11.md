state: implemented

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
