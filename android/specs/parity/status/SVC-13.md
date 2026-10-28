state: implemented

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
