state: reviewed

SVC-5 Diagnostics. Tests: 660 total, 0 failed (baseline 626; +34 new: SigV4Test 6, DiagKeyFileTest 7, DiagLogTest 17, DiagUploaderTest 4).

- [x] net/SigV4.kt (AWS S3 GET-Range + PUT vectors pass)
- [x] diag/: DiagLog, NPLog (11 lanes), DiagUploader (OkHttp SigV4 PUT), DiagUploadStatus, DiagKeyFile + importer, JankWatchdog, DiagSettings (+DiagCredentialStore in SecretStore), DiagServices wiring
- [x] Settings > Debug (DebugScreen.kt + DebugSection.kt, order 900, only on BuildConfig.DEBUG||DIAG_CHANNEL builds)
- [x] RemoteEndpoints.diagBucket; ServicesGraph: settingsSections, deepLinkHandlers, flushables

Deviations / notes
- Gate: build channel = DEBUG||DIAG_CHANNEL; uploads = channel && diagEnabled toggle (default true). Release => disabled, no network/files.
- installId is diag-private (SharedPreferences "pocketdj-diag"), not AppSettings' (that is suspend).
- New file outside owned list: diag/CaptureSessions.kt, diag/DiagServices.kt (additive).
- Shared files touched (minimal/additive): AppGraph.appContext private->internal; AndroidManifest (.pdjdiagkey VIEW intent-filter on MainActivity); app/build.gradle.kts (GIT_SHA buildConfigField); SettingsSections.DEBUG const.
- Jank watchdog + background flush hooked via ProcessLifecycleOwner in DiagServices.start() (no MainActivity edit). DiagLog is materialized when ServicesGraph.deepLinkHandlers is read (AppGraph init).
- Pairing-mismatch confirm in the deep-link path is a toast pointing to Settings > Debug (Import anyway button there).
- Device-only/emulator steps (real S3 PUT, Files open) not run.
