state: merged

# SURF-3 — Zero-to-hero onboarding

- [x] OnboardingStore (decide(), marker codec = iOS `pdj.onboarding.v1` JSON, advance/back/complete, waitUntilComplete, vetoIfIncomplete, forcePending, forceShow)
- [x] OnboardingSettings (DataStore marker storage, applyOnboardingSources pure fn + AppSettingsStore ext, profile-name pref `pdj.profile.name`)
- [x] LinkDeviceProbe seam (stub -> Unavailable until SVC-9; `ShellGraph.linkDeviceProbe` is the swap point)
- [x] 3-stage Compose flow (OnboardingScreen/Stages); stage 2 reuses MusicKitAuth, "Continue without Apple Music"
- [x] Shell gate in PocketDjApp (app not composed until complete => no screen-driven catalog/rips/jukebox loads); debug intent extra `pdj.showOnboarding=true`
- [x] Tests: OnboardingStoreTest + OnboardingMarkerCodecTest (32 new; suite 844 green)

## Files touched outside the owned list
- di/AppGraph.kt (additive): `hadPersistedSettingsAtLaunch` captured before the DataStore exists; `onboarding` accessor; `refreshEndpoints` awaits `onboarding.waitUntilComplete()` before the rips-manifest refresh.

## Notes / deviations
- Marker is read asynchronously: store reports loaded=false/complete=false (veto closed) until read.
- `applyOnboardingSources` tested in OnboardingStoreTest (AppSettingsStoreTest not owned).
- Profile name stored under pref `pdj.profile.name`; SET-x Profile section should adopt it.
- Gate-by-composition covers screen-driven loads; future launch-pipeline pieces (SVC sync push, jukebox bootstrap outside screens) must call `graph.onboarding.waitUntilComplete()`; ShellActions (SURF-5) must call `vetoIfIncomplete()`. SET-1 Reset calls `onboarding.forcePending()` AFTER the wipe.
- Emulator steps not run (shared emulator owned by integrator).

## Questions for Levi
- None blocking. Link-a-device stage is a stub until SVC-9.

## Review
Baseline JVM test count before fixes: 844 (32 from this package). fixes applied
- MAJOR rips manifest fetched pre-onboarding -> fixed: `runRipReconcileGated` (WorkScheduler.kt) awaits marker load and skips the run while incomplete; `RipsRepository.launchGate` (installed in AppGraph from onboarding) also holds `refresh`/`refreshStrict`. Tests: WorkSchedulerPolicyTest ripReconcileSkipsFetchWhileOnboardingIncomplete / ...FetchesOnceOnboardingComplete.
- MINOR forcePending racing clearAll -> fixed: `forcePending()` is now suspend and acks after the serialized write; documented it must run AFTER the settings wipe (SET-1/SVC-13). Test forcePending_suspendsUntilWritten. (No ShellGraph resetHooks entry added: the reset orchestrator does not exist yet; ordering contract documented on the method.)
- MINOR vetoIfIncomplete during load -> fixed: added `awaitLoaded()` and `vetoIfIncompleteAwaitingLoad()` (SURF-5 ShellActions must use the latter). Tests vetoAwaitingLoad_*.
- MINOR Start DJing unhandled IO failure -> fixed: try/catch (rethrows cancellation), logs, still calls `complete()` with default sources.
- MINOR ledger Planned -> fixed: docs/ARCHITECTURE-ANDROID.md row set to PARTIAL (veto wiring deferred to SURF-5, link probe stub until SVC-9, real AM sign-in device-only).
- MINOR AppGraph shared-file edits -> fixed/reduced: onboarding logic removed from `refreshEndpoints`; remaining AppGraph touches are `hadPersistedSettingsAtLaunch`, the `onboarding` accessor and a one-line `launchGate` install on ripsRepository (shared touchpoint, flag to integrator; gate itself lives on the rips side).
- NIT profile name orphan pref -> not changed: `pdj.profile.name` remains the SVC-7/SET-x migration source (noted above).
