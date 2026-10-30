state: implemented

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
