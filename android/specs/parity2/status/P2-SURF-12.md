state: merged

# P2-SURF-12 status: Android AppFunctions for Gemini (12 actions), runtime-gated on API 36+
- [x] Dependencies: androidx.appfunctions + appfunctions-service + appfunctions-compiler (KSP) all pinned 1.0.0-alpha08; KSP plugin 2.3.14 (new, applied in app only)
- [x] PocketDjAppFunctions.kt: 12 @AppFunction methods (addSongToCollection, addCurrentSongToCollection, setMixMode, muteStem, unmuteStem, playCollection, shuffleCollection, playMyPocket, startAutoMix, pauseAutoMix, resumeAutoMix, createPocket) -> AppFunctionsAdapter -> AppFunctionTarget (ShellActionsTarget = one line per ShellActions door)
- [x] Name resolution reuses CollectionNameMatcher (strict, never initials) + IntentSongMatcher; ShellActionException becomes the spoken line
- [x] Wiring: PocketDjApplication implements AppFunctionConfiguration.Provider; ShellGraph.appFunctionsAdapter()
- [x] Tests: PocketDjAppFunctionsTest (12). Full run: 7849 tests, 0 failures; testDebugUnitTest + assembleDebug + assembleRelease green (release needed a retry alone: the first combined run hit a Kotlin daemon OOM in compileReleaseKotlin, unrelated to code).

## Files touched outside owned list
- android/build.gradle.kts (ksp plugin, apply false), gradle/libs.versions.toml, app/build.gradle.kts (ksp plugin + 3 deps), PocketDjApplication.kt (Provider), di/ShellGraph.kt (appFunctionsAdapter). AndroidManifest.xml NOT edited: the library's merged manifest declares its service, enabled only on API 36+ by its own bool resource.

## Deviations / notes
- Pinned alpha08, not 1.0.0 or alpha09: both of those declare minCompileSdk=37 (this project compiles against 36, and platform 37 is not installed); alpha08 is the newest with minCompileSdk=36. Stable 1.0.0 also has a redesigned API (AppFunctionServiceEntryPoint / metadata) unlike the documented annotation API.
- Gating on SDK_INT>=36 is done by the library (its service is disabled below 36); minSdk stays 35.
- Auto-mix sources resolve pockets and playlists by name (no set lists); shuffle defaults false (iOS).
- Not run: emulator `cmd app_function list-app-functions` (API 36 image, integrator-owned) and Gemini on a device.

## Questions for Levi
- Move to appfunctions 1.0.0 stable? It needs compileSdk 37 (install platform 37, bump compileSdk across the app) and a port to its new service API. Alpha08 is shipping in a live Play build until then.

## Review
- MINOR auto-mix set lists -> fixed (documented): startAutoMix KDoc, which Gemini reads, now says set lists are not supported; resolving them was not added.
- MINOR R8 survival -> partially fixed: added keep rules (appfunctions library, PocketDjAppFunctions, generated *_AppFunctionInventory / *_AppFunctionFactory) to proguard-rules.pro. The emulator check (`cmd app_function list-app-functions` on a minified release build, API 36) was NOT run (emulator is integrator-owned); integrator should run it.
- MINOR test coverage -> fixed: added a test that PocketDjAppFunctions delegates all 12 functions to the right adapter calls (suite 7849 -> 7850, 0 failures). ShellActionsTarget mapping and KSP wiring remain untested (need the concrete ShellActions graph / instrumentation).
- NIT alpha08 -> no change; 1.0.0 move tracked in Questions for Levi.

fixes applied
