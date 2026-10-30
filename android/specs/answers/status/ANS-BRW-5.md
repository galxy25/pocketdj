state: merged

ANS-BRW-5: ShazamKit for Android 2.1.1 live recognition backend.
- [x] AAR vendored at app/libs/shazamkit-android-release.aar; build.gradle.kts implementation(files) + gson + pickFirst libc++_shared.so (mediaplayback AAR also bundles it).
- [x] ShazamKitBackend (token via MusicKitDeveloperTokenClient, StreamingSession, AudioRecord 48k mono PCM16, 12s timeout -> NoMatch), logic in ShazamStreamDriver with fakes.
- [x] BrowseGraph: release = ShazamKitBackend; debug keeps DebugListeningBackend.
- [x] Keep rules appended to proguard-rules.pro (AAR also ships consumer rules). Minify is still off on this branch, so assembleRelease R8 was not exercised here.
- Tests: 9 new (ShazamKitBackendTest); total JVM tests 5420.
- Touched outside owned list: app/proguard-rules.pro (additive).
- Device-only: live mic recognition.

## Questions for Levi
- None. (Re-verify R8 keep rules with assembleRelease once the release-build branch with minify is merged.)

## Review
- MAJOR retrofit missing from APK -> fixed: libs.versions.toml now has retrofit 2.9.0 + converter-gson + gson (libs.*); retrofit2.OkHttpCall confirmed in the debug APK dex. Test `shazamkit_transitive_runtime_classes_are_on_classpath` would have caught it.
- MINOR R8 unverified / proguard conflict -> fixed: duplicate keep rules dropped (proguard-rules.pro reverted to base; the AAR's consumer rules apply). Verified `:app:assembleRelease` (minify on) succeeds in a scratch worktree of this branch merged with main (a392e649+); no missing-class errors.
- MINOR AudioRecord state unchecked -> fixed: AudioRecordPcm.start checks STATE_INITIALIZED/recordingState, throws MicUnavailableException; driver maps start() failure to Error("Microphone unavailable...") and releases. Test added.
- MINOR backend.recognize() untested -> fixed: 3 tests (unconfigured server -> Error, throwing sessionFactory -> Error, token passed to provider -> Hit).
- NIT g.log -> fixed (removed).
- NIT gson inline coordinate -> fixed (catalog).
- NIT matchStream timestamp -> rejected: unverifiable without a device run; stream-relative ms is the documented StreamingSession semantic; left as is, device-verify.
- Tests: 5420 -> 5425, 0 failures; testDebugUnitTest + assembleDebug green.

fixes applied
