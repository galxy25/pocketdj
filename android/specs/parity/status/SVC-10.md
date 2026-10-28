state: implemented

# SVC-10 status
- [x] SettingsCredentialsDocument (iOS keys, sorted-key canonical encode, credentialsAreBlank)
- [x] CredentialsSync (syncIfChanged, applyPulled, pure merge with empty-secret guards, ProfileHeader)
- [x] DiagKeySync (own "diag-key" doc, empty never wins)
- [x] X-PocketDJ-Profile on RipServerClient + JukeboxClient (Config.profileId; sent only when enrolled)
- [x] ServicesGraph: syncEntries (settings-credentials, diag-key), port adapter, watcher that mirrors edits
- [x] Tests: CredentialsSyncTest, DiagKeySyncTest, ProfileHeaderTest

## Files touched outside owned list
- di/AppGraph.kt (ripConfigProvider: +profileId line), data/jukebox/JukeboxGraph.kt (config provider: +profileId line)

## Deviations
- `sources` is decoded but never pushed or applied on Android: Android source ids are not UUIDs, which would fail the iOS Codable decode of the whole doc.
- appleMusicPrivateSync not an Android setting: never written.
- Profile header uses the ENROLLED profile id (ProfileSecretStore.enrolledProfileId), per roadmap "only when enrolled"; JukeboxGuestClient unchanged (public, out of scope).

## Questions for Levi
- Should Android adopt synced catalog `sources` from iOS (needs UUID-vs-"vinyl" id reconciliation)? Defaulted to no.

## Result
22 new JVM tests (13 CredentialsSync, 5 DiagKeySync, 4 ProfileHeader); full suite 3703 tests, 0 failures; assembleDebug green.
Note: build needed a bigger Kotlin daemon heap (-Dorg.gradle.jvmargs=-Xmx4g -Pkotlin.daemon.jvm.options=-Xmx4g) — default 2g OOMs compiling SetlistSequencer (unrelated, gradle.properties untouched).
