state: reviewed

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

## Review

fixes applied

- MAJOR (double abort, backend never restored) -> fixed. AppleMusicBackend.play's cancel handler does the SDK stop; the controller restore (`restoreAfterCancelledAmStart`, no longer gated on abortPendingStart's boolean) now always clears amCurrentAmId, restores activeBackend and resumes Exo if prior==EXO, unless a newer loadAppleMusic (amStartSeq) owns state. Tests: 3 `controllerRestore_*` in AppleMusicCancelledStartTest (restore with SDK abort already done; superseded start untouched; AM prior no Exo resume).
- MINOR (abortPendingStart songId guard) -> fixed. Now private, guards on the per-start Current instance identity (`current !== start`).
- MINOR (stall episode leaking) -> fixed. endStallEpisode also runs on any current-row audio (before the pending-window early return in handleFirstAudio) and on AUTO advance.
- NIT (test seam) -> fixed via the extracted restore helper + tests above.

Tests: 5797 JVM, 0 failures (+3). assembleDebug green. Built with FIN_MIN_FREE_GB=5 (default 8 never cleared on a quiet machine).
