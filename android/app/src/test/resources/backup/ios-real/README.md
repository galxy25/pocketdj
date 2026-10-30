# Real iOS-exported fixtures (ANS-SVC-2)

These bytes were written by the actual iOS exporters (`BackupZip.export`,
`CollectionsStore.exportPocketZip` -> `PocketZip`, `exportPlaylistZip` -> `PlaylistZip`),
not hand-built. The source store is SYNTHETIC (the `TestData` Test Crate catalog; no real
user library data).

Regenerate (iOS Simulator, ~1 min):

    apple/scripts/export-android-fixtures.sh

which runs the opt-in `PocketDJTests/FixtureExportTests` (skips unless `PDJ_FIXTURE_OUT` is set;
the script passes it as `TEST_RUNNER_PDJ_FIXTURE_OUT`, `CODE_SIGNING_ALLOWED=NO`).

Files: `backup.pocketdj.zip`, `pocket.pdjcollection`, `playlist.pdjcollection`.
Ids are random per generation; `IosRealFixtureTest` asserts on names/structure, and that
`amPlaylistId` never appears (ANS-COL-1).

Content: folder "Gigs"; pockets "Warmups" (child "Chill", album, repeats, note, cleanOnly,
recsEnabled=false, amSyncDirection=pull, in folder) ; playlist "Night Set" (2 chapters,
pocket/album/song/text nodes, repeat 2, cleanOnly, recs off, push, in folder); one setlist
(seed `fixture-seed`); favorites with a tombstone; album/song edits; one source.
