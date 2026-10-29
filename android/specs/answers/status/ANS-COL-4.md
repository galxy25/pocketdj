state: implemented

# ANS-COL-4 Burn folder mirrors stems + beat grids; delete removes folder copy
- [x] BurnTree.delete(name); BurnFolder.deleteMirrored(treeUri, names) (no-op unreachable/unconfigured); BurnItem.treeUri stamped at finalize (burn, adoptStreamedFile, finalizeTransfer)
- [x] mirrorFiles after burnCollectionStems/beat grids, burnStems, burnStemPart, burnBeatGrid, adoptStreamedStems; .json copied as application/json
- [x] removeBurns/removeAuxFiles/removeAllBurns/removeStems/removeAllStems delete folder copies; eviction (removeBurns(mirrored=false), sweepOrphanAuxFiles) stays local-only
- [x] 10 new JVM tests in BurnFolderSafTest; suite 5221 tests, 0 failures; assembleDebug green

## Deviations
- Touched outside owned files: data/storage/StorageManager.kt (BurnStorePruneAdapter calls removeBurns(ids, mirrored=false)), one line.
- Pre-existing transfer-worker mirror path (BurnDownloadWorker) unchanged; stems in that path mirror via burnCollectionStems at run end.

## Questions for Levi
None.
