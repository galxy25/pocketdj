state: in-progress

# P2-REM-6 - RemoteSessionController part 2 (speaker half)

- [x] RemoteLocalChanges.kt: LocalObservation, cause-tagged diffing (USER/NATURAL_END/AUTO_SKIP/STALL_HOP/UNPLAYABLE/REMOTE), scrub detection, queue-edit commands, pending hold
- [x] RemoteReconciler.kt: reconcile (tail edit / jumpToUpcoming / fresh play), drift, session seek, play re-issue, pausedHere/rejoin, availability report, MixTogetherBlock
- [x] Wiring: RemoteGraph.wire binds the reconciler, systemPaused seam, controller silencer (Mix decks + NP DSP host via MixGraph.silenceForRemoteController)
- [x] Suspensions: AutoDj refuses start/enable/resume while MixTogetherBlock is set; ShellActions vetoes with MixTogetherActive (Assistant link + Auto Mix tab)
- [ ] Tests green, count moved
