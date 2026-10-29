state: reviewed

# ANS-COL-1 — Persist amPlaylistId on Pockets AND Playlists

- [x] Kotlin: Pocket @Transient removed; PlaylistSerializer reads/writes amPlaylistId (lenient); sanitizePocketFlags drops non-string
- [x] Kotlin: PocketZip/PlaylistZip/CollectionFile envelope export strip the field; import upsert/remint still strip
- [x] iOS: CodingKeys + try? decode + memberwise inits (Pocket, Playlist); `strippedForExport` used in zips + exportPocket/exportPlaylist envelopes
- [x] Tests written (Kotlin + Swift)
- [x] Gradle green; iOS unit: 3334 run, only unrelated TransferCoordinator timeout under load

Touched outside owned files: apple/PocketDJ/State/CollectionsStore.swift (exportPocket/exportPlaylist use strippedForExport, 2 lines).

Note: Gradle needs -Dorg.gradle.jvmargs=-Xmx5g -Pkotlin.daemon.jvmargs=-Xmx5g when many packages build in parallel (OOM otherwise).
## Questions for Levi
none

## Review
- MINOR BackupZip exports carried amPlaylistId -> fixed: Android BackupZip.export and iOS BackupZip.export strip it (copy(amPlaylistId=null) / strippedForExport); tests BackupZipTest.backupExportNeverCarriesAmPlaylistId + BackupZipTests.testBackupExportNeverCarriesAmPlaylistId.
- MINOR cross-fixture only half met -> fixed: shared fixture android/app/src/test/resources/collections/am-playlist-id-shared.json decoded + re-encoded by both Kotlin (CollectionsCodecParityTest) and iOS (CollectionsLossyDecodeTests); AMPlaylistSyncTests.testLinkSurvivesEncodeDecodeRoundTrip added. The fixture is hand-authored in the iOS encoder's key shape, not captured output; the iOS test also checks the iOS encoder emits a string key.
- NIT iOS count/flaky -> partly done: targeted iOS run (CollectionsLossyDecodeTests, BackupZipTests, AMPlaylistSyncTests, TransferCoordinatorTests) 59 tests, 0 failures; TransferCoordinatorTests passes alone (load flake confirmed). Full-suite baseline count not re-taken.
- Gradle: 5135 -> 5137 unit tests (+2 Kotlin), 0 failures; assembleDebug OK.

fixes applied
