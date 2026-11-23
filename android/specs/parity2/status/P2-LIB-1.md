state: in-progress

BLOCKED ON BUILD: code + tests written and committed but NOT yet compiled/run. one-at-a-time.sh is machine-wide deadlocked: lock held by P2-POC-1 (pid 697) which waits for free>=8GB, machine has ~6-7GB (free+inactive+speculative) with NO build running; 8 packages queued behind it. Needs FIN_MIN_FREE_GB lowered or memory freed, then run: ./gradlew :app:testDebugUnitTest :app:assembleDebug

# P2-LIB-1 — Credentials same-HOST guard + rip-server auth hold

- [x] CredentialsSync.sameServerHost / serverHost (pure string parsing; android.net.Uri is stubbed on the JVM) + keepLocalSecret uses it
- [x] RipAuthState (token-scoped rejectedToken/rejectedAt, memory only, 120 s re-probe, revision flow)
- [x] RipServerClient: RipUnauthorizedException, noteStatus on every authed call (execute + raw calls), isAuthRejected/authHoldoff, health(candidate) excluded
- [x] BatchRipResult.refusedStatus (non-2xx = status, transport/decode failure = -1, no per-song storm fallback)
- [x] PresignCache.prefetch + RipCollectionCoordinator(automatic=true) hold off; burn bar copy + skip automatic rip-missing
- [x] Tests: CredentialsSyncHostGuardTest, RipAuthHoldTest
- [ ] Gradle green, count moved

## Files outside the owned list (minimal, additive)
- data/rips/RipsModels.kt: BatchRipResult.refusedStatus + `unauthorized`
- data/rips/RipAuthState.kt: new file (shared state class)
- di/AppGraph.kt: one line wiring `authHoldoff` into PresignCache

## Deviations / notes
- `RipServerClient.ripCollection` no longer falls back per-song on transport/decode failure (iOS 1bad0e9d behavior); 404 and unconfigured still fall back.
- Burn lane (BurnStore / HttpBurnRips) and the Mix rip lane (MixGraph:1106, CollectionMixDownloader) are other packages' files: they can now call `ripServerClient.authHoldoff()/isAuthRejected()` and `coordinator.ripCollection(ids, isRipped, automatic = true)`; not wired here.

## Questions for Levi
- none
