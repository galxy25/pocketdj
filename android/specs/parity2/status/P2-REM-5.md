state: implemented

# P2-REM-5 - RemoteSessionController part 1 (host/session half) + RemoteGraph

- [x] RemoteElection.kt: shouldYield (HostClaim), lowest-id winner, joinerAction (re-hello 8 s / self-host only alone), fitState (size cap by halving), StateRequestTracker (2 s doubling to 16 s), RemoteTuning constants
- [x] RemoteSessionController.kt: attach/leave/setLocalRole, host model + broadcast (revision change / joiner / request), heartbeat 2 s, state requests, hand-over (takeOverAsHost), empty-host guard, refill from local set, host self-advance, ping/pong, controller silence per tick, interceptLocalTransport, extension points, observable StateFlows (isActive, state, roster, peers...)
- [x] RemoteSpeakerHooks: the seam P2-REM-6 binds (`controller.speaker = ...`): reconcile, onWindowChanged, onStructuralState, rejoin, onAttach/onEnd/onRoleChanged. Default no-op. Setters for the speaker half: setPausedHere, setLocalUnavailable, setStatus; `ridByUid`, `post`, `lastRevision` are public.
- [x] RemoteGraph.kt (FeatureModule "remote"): lazy controller/target/resolver/clock; wire() binds RemoteControllerGate (isController + forwarder) and DjModeWiring.bindRemote(probe)
- [x] Tests: RemoteElectionTest (8), RemoteSessionHostTest (24) = 32 new; suite 7056 total, 0 failures

## Files touched outside owned list
- di/AppGraph.kt: `remoteGraph` lazy, added to the features list, `remoteGraph.wire()` launched on Main inside PLAYBACK_WIRE (shared touchpoint)
- diag/NPLog.kt: `REMOTE = "remote"` lane const (not in LANES)

## Deviations
- The speaker reconcile/drift/local-change diffing is NOT here (P2-REM-6); the host's own `refillFromLocalSource` and seeding from the local player are.
- `participants` is a StateFlow here (never completes), so session end is detected as the roster going empty after having been non-empty.
- Showcase seed (fake Car hub) not ported (not in this package's acceptance).
- assembleRelease not run: no manifest/gradle/proguard/library change.
- one-at-a-time.sh refused `--no-quiesce-fin` (7 GB model resident), so builds ran with the default quiesce (Fin was restored by the script).

## Questions for Levi
- None.
