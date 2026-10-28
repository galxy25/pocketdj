state: merged

# COL-14 — .pdjcollection + backup .pocketdj.zip codecs, idempotent import merge, CSV

- [x] ZipIo (zip magic, sorted-entry deflate write, sorted-key compact JSON, ISO8601 seconds)
- [x] PortableItems (PWA MusicItem[] shape, null conventions, lenient dict decode, DAG closure)
- [x] PlaylistZip / PocketZip (export portable|slim, read with ids preserved, remintBundle kept for "import as copy")
- [x] TracklistCsv (iOS columns) + row resolver with ShareText links
- [x] CollectionFile: detectKind (content, not extension), CollectionsDocument envelopes, pure idempotent Merge
- [x] BackupZip / BackupModels (iOS entry names + manifest, PWA tolerance, raw sources/edits/favorites)
- [x] CollectionsStore import/export section (exportPocket/Playlist, export*Zip, export*Csv, importCollection, import*Zip, mergeBackupCollections, importAny(bytes), mergeImported, onPortableItems seam)
- [x] 44 new JVM tests (suite 4167 -> 4211, 0 failures); :app:assembleDebug green

## Notes / deviations
- Zip imports MERGE BY ID (ids preserved) per COL-14 acceptance; iOS' zip import reminted ids (and duplicated on re-import). `PlaylistZip.remintBundle` / `PocketZip.remintBundle` preserve the iOS behaviour for a deliberate "import as copy" (IO-2 / SET-2 can choose).
- A merge only re-stamps `updatedAt` on items it actually changed (iOS stamps always), so a re-import leaves sync-visible state untouched.
- CSV: roadmap acceptance says "incl. Sequence + Song ID" but iOS `TracklistCSV` (the stated source of truth) has NO such columns: `#,Title,Artist,Album,Year,Genre,Apple Music,Spotify,YouTube`. Followed iOS.
- `Pocket.amPlaylistId` is @Transient on Android (never on the wire), so strip-on-import is structural plus enforced on insert in the merge.
- ProfileSourceStore.isProfileSongId has no Android counterpart yet; only studio ids are excluded from items.json.
- BackupZip keeps sources/edits/favorites RAW (JsonArray / ByteArray); `BackupSources` maps iOS SourceConfig wire ({id,name,urlString,enabled}) <-> Android SourceConfig. SET-2 owns merging edits/favorites/sources.
- Fixtures are hand-built in the iOS/PWA shape (no real iOS-produced backup was available): pwa-playlist.pocketdj.zip, backup/ios-backup.pocketdj.zip, backup/ios-pocket.pdjcollection; plus the real iOS sample copied as fixtures/ios-sample-playlist.playlist.pocketdj.zip.
- Files added beyond the roadmap list (all new, in owned dirs): io/ZipIo.kt, io/PortableItems.kt, io/PocketZip.kt, io/TracklistCsv.kt; tests PortableItemsTest, PocketZipTest, TracklistCsvTest, IoTestSupport. No files outside ownership touched.
- Materializing portable items into a provisional catalog is left to the `onPortableItems` seam (Catalog package injects the ImportedSongsStore equivalent).

## Questions for Levi
- Should a shared .pdjcollection opened from Files import under FRESH ids (iOS behaviour, duplicates on re-import) or merge-by-id (this package's default, idempotent)? Chose merge-by-id.

## Review
fixes applied
- MAJOR sources non-UUID id -> fixed: BackupSources.wireId emits UUID (pass-through or name-based), matchLocal/merge match by wire id, url, then name for SET-2; tests androidDefaultSourcesExportAsUuids_andMergeWithoutDuplicates + updated sourcesWireShape.
- MINOR ledger row -> fixed: COL-14 set to PARTIAL (JVM) in docs/ARCHITECTURE-ANDROID.md.
- MINOR silent merge/no-op summary -> fixed: Merge.Result/ImportSummary carry added/merged/unchanged (+alreadyUpToDate); importPlaylistZipAsCopy / importPocketZipAsCopy use remintBundle. Test summaryDistinguishesAddedMergedUnchanged_andAsCopyAdds. COL-15 owns wiring the UI (copy vs merge prompt, "already up to date").
- MINOR hand-built fixtures -> PARTIAL/not fixable here (no Simulator export available in this run): acceptance marked PARTIAL in status + ledger; a real iOS export fixture is a follow-up.
- NIT zip cap -> fixed (512 MB inflated cap in ZipIo.read); double inflate in detectKind left as is.
- NIT profile song ids -> fixed as TODO(profile-source package) markers in PortableItems.
Tests: 4211 -> 4213, 0 failures; assembleDebug green.
