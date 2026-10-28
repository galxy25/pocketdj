state: implemented

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
