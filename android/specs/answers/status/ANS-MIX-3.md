state: in-progress

# ANS-MIX-3 Mix returns after process death + Mix disk work off Main

- [x] MixEngine.parkRestore / parkedCard / atomic off-main restore (restoreOffload) / prepared-load cache
- [x] MixGraph.launchRestore (PocketDjApplication first-foreground hook), restoreOffload wiring, ON_STOP hand-off to writer thread
- [x] AutoMixTab -> extras.materializePendingRestoreIfNeeded("autoRow")
- [x] Stores: snapshot under lock, encode off lock
- [x] Tests
- [ ] full suite + assembleDebug
