state: implemented

- [x] FOREGROUND_SERVICE_LOCATION permission + PlaybackService foregroundServiceType="mediaPlayback|location"
- [x] LocationFgsPolicy (pure) + PlaybackService.syncLocationFgsType: re-issues startForeground on Media3's notification with mediaPlayback|location only while playing AND places on AND while-in-use granted; resets when paused / toggled
- [x] LocationSettings.hasWhileInUse
- [x] Tests: LocationFgsPolicyTest (4), ManifestPermissionsTest (2)

Deviation (Levi C2 reversal, 2026-10-29): ACCESS_BACKGROUND_LOCATION stays declared and the "Allow Always" rows/disclosure flow stay; ManifestPermissionsTest asserts background IS declared (roadmap said removed).
assembleRelease green. Emulator steps not run (integrator owns the emulator). Play FGS-location declaration needed at submission.
