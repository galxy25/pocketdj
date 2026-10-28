state: implemented

# SURF-1 — Shell foundation

- [x] Gradle/Manifest sweep (D4): catalog deps, RECORD_AUDIO/POST_NOTIFICATIONS/FGS_DATA_SYNC/FGS_MEDIA_PLAYBACK/BT, FileProvider + file_paths.xml, empty shortcuts.xml, DIAG_CHANNEL buildConfigField (buildConfig=true)
- [x] PrefKey<T> + generic AppSettingsStore API (get/set/flow/update/remove/clearAll); LegacyPrefKeys freeze old names
- [x] SecretStore (EncryptedSharedPreferences) + SecretMigration (idempotent, blanks plaintext); AppSettings still exposes ripToken/jukeboxToken/musicUserToken (read from SecretStore, plaintext fallback pre-migration) so callers are untouched
- [x] PocketDjDestination: 7 destinations (+Games), pinned iOS tokens, History default
- [x] ShellRoute / ShellRouteResolver / NavRequestBus (atomic take, replace-not-queue, staged push 450 ms) / LastSectionStore
- [x] FeatureModule + FeatureModuleRegistry; eight sidecar graphs; AppGraph lists them once
- [x] IntentSink; MainActivity thin (forwards launch + onNewIntent)
- [x] Settings registry (SettingsSections) + sections/*; SettingsScreen renders the registry
- [x] ShellNavigation: NavigationSuiteScaffold (bar <600 dp labels on selected only, rail >=600), moved PocketDjApp + route helpers there
- [x] Tests (29 new, 307 total, 0 failures); assembleDebug green

## Notes / deviations
- Files touched outside owned list: none beyond owned set plus new `screens/settings/sections/` (Import server and Jukebox broker sections live in DataSourcesSection.kt).
- Settings helper composables renamed SettingsHeader/SettingsDivider (StorageScreen has a private SectionHeader in the same package).
- Rail layout chosen from LocalConfiguration.screenWidthDp (>=600) rather than the adaptive-info library.
- Route-miss feedback is a snackbar "Can't open that - <iOS message>" (iOS uses an alert).
- `ShellRoute.JukeboxJoin` resolves only for joined sessions; none exist until JBX-2, so it returns a message for now. `pendingBrowseQuery` is set on NavRequestBus; Browse must consume it (BRW package).
- `PlayOutcomeListener` is a minimal shell-package interface; PB-5 may supersede/adapt.
- Games destination is a PlaceholderScreen (phase 5).
- Not done by design: docs/ARCHITECTURE-ANDROID.md ledger (integrator). Emulator steps not run (emulator owned by integrator).
