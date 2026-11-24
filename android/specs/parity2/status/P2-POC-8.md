state: in-progress

# P2-POC-8 Pocket run store

- [x] PocketTuning.verdicts(History -> verdicts), PocketTuningTest
- [x] PocketRunStore (start, 1 Hz evaluate, bans from this run, debounced replan, W2 trim/top-up, ownership grace, held run, persistence, retarget, Mix seam)
- [x] SetlistSequencer.pocketRunTagFor + PlaybackContract/Controller/Service `pdj.pocketRun` extra (History `pocketRun` stamp)
- [x] UpNextList "Re-tuned" badge (np-retuned), PocketsGraph.runStore wiring, wheelController.play, Debug buttons
- [ ] full test + assembleDebug green
