state: reviewed

# COL-15 - .pdjcollection / backup export-import UI, file-open handler, Imported source, Settings Backup

- [x] ImportedSongsStore (pocketdj-imported-songs.json, lenient doc, stable synthetic IndexJson 'Imported', amrec_ supersede)
- [x] CatalogRepository.syntheticDocuments wired in CollectionsGraph (real sources shadow by merge order); change -> catalog refresh
- [x] CollectionShare (explicit-extension names, summary/failure messages, bounded Uri IO)
- [x] CollectionExportImport.kt (CreateDocument exporter zip/CSV, OpenDocument importer)
- [x] PlaylistsScreen: Import toolbar button; Export... / Export CSV in playlist + pocket row menus
- [x] CollectionImportSeam claims DeepLinkSeams.importCollection (installed from CollectionsGraph.deepLinkHandlers)
- [x] Settings > Backup section (export/restore .pocketdj.zip: sources merge, collections, favorites)
- [x] Tests: ImportedSongsStoreTest (5), CollectionExportImportTest (4), CollectionImportSeamTest (3) = 12+; suite 4478 tests, 0 failures; assembleDebug OK

## Notes / deviations
- Manifest intent-filters already existed from SURF-4; unchanged.
- Setlist/playlist/pocket DETAIL-screen overflow menus (not owned) were not touched; export lives on the Collections list rows. Setlist CSV request builder exists (CollectionExportRequests.setlistCsv) for wiring.
- CollectionsGraph wiring of the store seams happens inside wireWriteBack (called once from AppGraph's collections initializer) to avoid a lazy-init cycle; no AppGraph edit.
- Backup `edits` entry is written empty ({}); no Android edits store exists.

## Questions for Levi
- None.
