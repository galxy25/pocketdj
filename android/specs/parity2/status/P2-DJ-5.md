state: merged

Summary: DjMode.kt (DJModeState with opaque planner JsonElement, DJModeSettings, Timings, fastSkip 5s, Indicator + chipText, DjEndReason decline words); MixSettings gains 7 dj* keys (missing => true) + mixVolumeGlide (missing => false) exposed as MixSettings.dj / .mixVolumeGlide; MixSection is now one "Mixing" row opening MixingSettingsScreen (route settings/mixing) with Crossfades / Now Playing DJ Mode / Mix tab groups and tags settings-dj-*.

Tests: 12 new (DjModeTest 8, MixSettingsDjKeysTest 4); :app:testDebugUnitTest total 5916, 0 failures; assembleDebug green. assembleRelease not run (no manifest/gradle/proguard/library change).

Deviations / touched outside owned files (minimal, additive):
- shell/FeatureModule.kt: SettingsHost.openMixing() default no-op; screens/settings/SettingsScreen.kt: onOpenMixing param. ShellNavigation.kt: route settings/mixing + title.
- DJModeState.planner is raw JsonElement? (DJSetPlanner.State doesn't exist on Android yet).
- Suspended-remote chip uses iOS verbatim "DJ — paused · SharePlay session" (design doc §6.1 text says "Remote session"; roadmap says verbatim).
- mixVolumeGlide and dj* toggles are persisted only; no engine consumes them yet (engine packages).

## Questions for Levi
- Suspended-remote chip wording: iOS "SharePlay session" vs design "Remote session" on Android (kept iOS).

## Review
- MINOR DjMode.kt chip "SharePlay session": deferred, not changed. The wording is an open question for Levi (see Questions above); iOS-verbatim is what the roadmap asks for. DjModeTest pins the string, so changing it later is a one-line diff in two places.
- NIT MixingSettingsScreen early return: left as is. It is deliberate, so a tap on defaults can never overwrite the stored value.
- NIT SettingsHost.openMixing default no-op: SettingsScreen is the only production host (other files only reference the type). Any new host must override openMixing().

fixes applied
