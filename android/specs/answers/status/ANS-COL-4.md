state: reviewed

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

## Review
- MAJOR BurnStore mirror on caller (Main) dispatcher -> fixed: burnStems/burnStemPart/burnBeatGrid/collection mirrors go through mirrorIO (withContext(Dispatchers.IO)); test mirrorCopiesRunOffTheCallingThread.
- MAJOR O(N x folder) deletes + duplicate aux delete -> fixed: BurnTree.deleteAll(names) lists the tree once (ContentResolverBurnTree override); removeAuxFiles is local-only, aux folder copies deleted once in the batched deleteMirrored; test removeBurnsListsTheTreeOncePerBatchWithoutDuplicates.
- MINOR double stem mirroring -> fixed: stems step mirrors stem names only, beat-grid step only the grid, adoptStreamedStems only moved parts; test collectionBurnWritesEachStemToTheTreeOnce.
- MINOR delete from current tree not item tree -> fixed: all item deletes use item.treeUri (legacy null still falls back to the current choice, documented); extra current-tree pass removed (only for app-storage items with aux staged in a user root); test deleteGoesToTheTreeTheItemWasFinalizedInto.
- NIT eviction test bypassed adapter -> fixed: storageEvictionAdapterKeepsFolderCopies drives BurnStorePruneAdapter.

fixes applied. Suite 5226 tests (+5), 0 failures; assembleDebug green.
