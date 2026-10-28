state: merged

# SVC-13 Reset everything + account deletion

- [x] AppResetService (device reset; hold pushes, collections, caches, secrets, settings keep installId, onboarding pending AFTER settings, sync state)
- [x] AccountDeletionService (stop live activity, cloud docs + DELETE /profile bounded best-effort, local stores + area resetHooks, media, settings, sync state, identity LAST once)
- [x] ResetSection (typed-confirmation dialogs RESET / DELETE, relaunch via AlarmManager + kill)
- [x] ServicesGraph wiring (appReset, accountDeletion; section registered at order 950)
- [x] Tests: AppResetOrderTest (7), AccountDeletionTest (9) = 16 new; suite 4009 tests, 0 failures

## Deviations / files outside the owned list
- AppSettingsStore.kt: additive `resetInstallId()` and `resetToDefaultsKeepingInstallId()`.
- ServicesGraph resetHooks: removed `clearLocalSyncState` and `profileSecrets.clear()` hooks; AccountDeletionService runs them explicitly in iOS order (nothing else invoked them; FeatureModuleRegistry.resetAll has no callers).
- Games hook `friends.eraseAll(); mwfJoinSecret.reset()` still runs in the local-stores phase (not last) - minor ordering divergence from iOS.
- Device reset does not run FeatureModule hooks (iOS Settings reset = settings + collections only); account deletion does.
- cloudDocKeys is the Android registry (13 keys), not iOS's list; lockstep tested by constants plus a SyncEntry( construction-site count scan. Deletion also unions live `features.syncEntries` keys at runtime.
- Jukebox session is ended via JukeboxRepository.end() (clears its session store).

## Questions for Levi
- None blocking. Account deletion lives in the same Reset section (iOS puts it under Profile); say if you want it moved.

## Review
fixes applied (suite 4009 -> 4015 tests, 0 failures; +3 AccountDeletionTest tombstone cases, +3 PendingCloudErasureTest; AppResetOrderTest order now asserts the mix step)
- MAJOR device reset never ejects Mix -> fixed: AppResetService `mix-decks` step after hold-pushes (ejectAll on Main + MixDeckSessionStore.clear()).
- MAJOR cloud delete not retryable -> fixed: failed/timed-out DELETE /profile writes a Keystore tombstone (old id + secret) BEFORE identity clear; `retryPendingErasure()` runs each launch via S3CloudDocDatabase.deleteProfileAs (401/404 = final). Tests: tombstone ordering/absence cases + PendingCloudErasureTest.
- MAJOR playback session not cleared -> fixed: explicit `playback-session` local step.
- MINOR fixed-delay kill -> fixed: `drainWriters()` (features.flushAll + awaitWrites on collections/session/mix writers) replaces delay(400).
- MINOR IO-thread Main-only calls -> fixed: sequencer.stop / ejectAll wrapped in withContext(Main).
- MINOR alarm relaunch -> fixed: startActivity(makeRestartActivityTask) from the foreground + exit(0). NOT emulator-verified (integrator owns the emulator).
- MINOR diag-key local file -> fixed: `diag-key` step deletes the file and clears the stored key.
- MINOR failures never shown -> fixed: when any step failed a dialog lists the failed steps before the Restart button (no silent kill).
- MINOR acceptance gaps -> PARTIAL: ledger row updated; cloudDocKeys-vs-live-registry and file-layout tests need a Robolectric/Context-backed ServicesGraph, rejected for this pass (the graph is not constructible in JVM tests); the wiring risk is covered by the runtime union with features.syncEntries.
- NIT UX differences -> recorded as intentional deviations: typed RESET/DELETE confirms, Delete account in the Reset section, MusicKit user token cleared by device reset.
