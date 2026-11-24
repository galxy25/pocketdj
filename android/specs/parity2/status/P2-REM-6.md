state: implemented

# P2-REM-6 - RemoteSessionController part 2 (speaker half)

Summary: the speaker half of a Remote session is bound as the controller's `RemoteSpeakerHooks`.
`RemoteReconciler` makes the local player match the session (tail edit / `jumpToUpcoming(uid, atMs)` / fresh
`play(startIndex, atMs, startPaused)`), corrects drift (750 ms, 2000 ms coarse, 2 strikes, 5 s cooldown, never while
buffering), applies a new-revision position change as an immediate session seek, re-issues a ▶/⏸ that didn't take after
2 s, reports availability once per change, and sets `pausedHere` on a system pause (never auto-resumed; ▶ or Rejoin
resumes at the session position, nothing sent). `RemoteLocalChanges` diffs the player against the last reconcile and
turns only the listener's own actions into commands by `TransitionCause` (USER -> command; NATURAL_END -> `advanced`
only within 10 s of the row's end, else hold silent; AUTO_SKIP/STALL_HOP/UNPLAYABLE -> unplayable here; REMOTE never
echoed), scrubs > 3 s (own seek landing excluded), queue edits, repeat/shuffle, and the 3 s pendingHold.

- [x] RemoteLocalChanges.kt (LocalObservation, diff, automaticTransition, queueEditCommands, hold state)
- [x] RemoteReconciler.kt (reconcile, syncTail/remap, drift, pausedHere/rejoin, availability, ReconcileTuning, MixTogetherBlock)
- [x] RemoteGraph.wire: binds the reconciler; `systemPaused` seam now wired to `SystemPauseState`; controller silencer for the Mix decks + NP DSP host (`MixGraph.silenceForRemoteController`, run every tick by the controller)
- [x] Suspensions: DJ Mode already suspended via the bound probe (P2-REM-5). Auto-DJ: `startAutoMix` / `setAutoEnabled(true)` / `resumeAuto` refuse while `MixTogetherBlock.reason` is set; `ShellActions.startAutoMix` (both overloads) throws `MixTogetherActive("Auto DJ is off while you mix together.")`, which the Assistant link seam and the Auto Mix tab already surface as messages
- [x] Tests: RemoteReconcilerTest (25, over LoopbackHub incl. latency + dropped state), RemoteLocalChangesTest (19)

## Tests
44 new tests; full suite 7303 run, 0 failures (`:app:testDebugUnitTest :app:assembleDebug` green). assembleRelease not run: no manifest/gradle/proguard/library change.

## Files touched outside the owned list (all minimal, additive)
- remote/RemoteSongResolver.kt: `RemoteResolutionCache.retainOnly(live)` (bounded cache)
- di/RemoteGraph.kt: wire() binds reconciler + silencer + MixTogetherBlock listener; target gets `systemPaused`
- di/MixGraph.kt: `silenceForRemoteController()` (never builds an unbuilt engine)
- mix/engine/AutoDj.kt: `blockedReason`, `onAutoBlocked()`, refusals in startAutoMix/setAutoEnabled/resumeAuto
- shell/ShellActions.kt: `MixTogetherActive` exception + `vetoDuringMixTogether()` in both startAutoMix overloads
- assistant/MediaSearchHandler.kt: NOT changed (its play paths never start Auto-DJ; the Assistant's auto-mix route is ShellActions, covered above)

## Deviations
- iOS keeps `autoDJBlockedReason` on MixEngine and remembers an explicit Auto OFF across a block (`autoEnabledBeforeBlock`); here the block is the process-wide `MixTogetherBlock` (Mix Together, P2-REM-11, sets it via `MixTogetherBlock.set(reason)`; nothing sets it yet) and a block simply turns Auto mode off. Restoring the prior Auto setting after a session is left to P2-REM-11.
- Resolution cache reuses `RemoteResolutionCache` (fuzzy rung only for current row + 3 ahead, same as iOS); rows in `locallyFailed` are still resolved by the cache but reported unavailable.
- Showcase seed still not ported (P2-REM-8).

## Questions for Levi
- None blocking. Confirm Auto OFF should not auto-restore after a Mix Together session ends (iOS restores the prior setting).
