state: implemented

# P2-PB-1 Apple Music cancelled-start fix (FR1) + stall episodes

Summary: loadAppleMusic no longer swallows CancellationException (new internal helper runCancellableAppleMusicStart in
AppleMusicCancelledStart.kt): on cancel, in NonCancellable, the SDK is stopped (AppleMusicBackend.abortPendingStart, a no-op
if a successor start already owns the SDK), activeBackend restored, then rethrown. AppleMusicBackend.play also aborts on cancel
after prepare(playWhenReady). ResolveStallHop.choose(abandoned); SetlistSequencer keeps the episode set, ends it on first audio /
user transport (noteUserTransport) / stop (endRun) and logs "stall episode end reason=<first-audio|user|stop> abandoned=N".
No eligible target keeps the current row buffering (existing behavior; deferred row stays right behind via apply).

- [x] all sub-steps; testDebugUnitTest + assembleDebug green. Total JVM tests now: 5794 (14 added: 5 + 5 + 4).

Deviations: AppleMusicPlayerAdapter.kt and NPLog.kt untouched (not needed; claim prevented by stopping the SDK). New file
AppleMusicCancelledStart.kt (pure helper so the JVM can test the cancel path). The AM test uses a fake SDK around the helper,
not the real AppleMusicBackend (Android-bound). Not run: assembleRelease (no manifest/gradle/proguard change).

## Questions for Levi
None.
