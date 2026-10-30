state: implemented

Real iOS-exported fixtures now back Android import tests.

- [x] apple/Tests/Unit/FixtureExportTests.swift: opt-in (XCTSkip unless PDJ_FIXTURE_OUT); synthetic store (folder, nested pockets, repeats, note, cleanOnly/recsEnabled/sync direction, multi-chapter playlist, setlist, favorites+tombstone, edits, source); runs BackupZip.export, exportPocketZip, exportPlaylistZip. Also links amPlaylistId to prove it never travels.
- [x] apple/scripts/export-android-fixtures.sh: xcodegen + xcodebuild test -only-testing:PocketDJTests/FixtureExportTests, TEST_RUNNER_PDJ_FIXTURE_OUT, CODE_SIGNING_ALLOWED=NO; removes apple/build.
- [x] Fixtures in android/app/src/test/resources/backup/ios-real/ (+README). sha256:
  - backup.pocketdj.zip 9236469eead32cfb483da92ed16f8336fe4e4036a98a2c9f22d67170247f4852
  - playlist.pdjcollection eceb762aa97aea01f86754dd66a2b08dd17eed6f3b11eda4c54fbf38d4729497
  - pocket.pdjcollection 2cf12124c008a48becaccb4d3ca687ef124ec4e83b1e63a8f0408847881d74db
- [x] IosRealFixtureTest.kt: 7 tests (full model, favorites/edits bytes, amPlaylistId absence, manifest, pocket file, playlist file, importAny + idempotent re-import).
- [x] Swift run: 1 test executed, 0 failures (the suite's other tests untouched; new test file only).
- [x] Gradle: testDebugUnitTest + assembleDebug green; 5349 tests, 0 failures, 0 skipped; +7 new.

Notes: no files outside owned set touched. Gradle needed -Pkotlin.compiler.execution.strategy=in-process due to Kotlin daemon OOM under parallel packages (not committed).

## Questions for Levi
None.
