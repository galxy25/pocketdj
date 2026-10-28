state: reviewed

# SVC-14 User-browsable burn folder via SAF

- [x] BurnFolder.kt: BurnTree (SAF layer seam), BurnFolderPrefs, SafBurnFolder, BurnDestinationResolver, BurnRoot.treeUri
- [x] TransferRecord.burnFolderTreeUri (additive); BurnStore stamps it at enqueue
- [x] BurnDownloadRunner resolves destination from the RECORD only; unavailable tree / copy failure falls back to app storage and finalizes with wasAppStorage=true
- [x] ContentResolverBurnTree (DocumentsContract) + SharedPrefs prefs; ServicesGraph wiring
- [x] StorageScreen: Burn folder section (OpenDocumentTree, persistable grant, "Use app storage")
- [x] Tests: BurnFolderSafTest (9), DestinationCaptureTest (7) = 16 new

## Design / deviations
- SAF has no File path and the whole pipeline (playback, eviction, stems) is File-based. The user root's dir is a local staging dir (filesDir/burns-user) that the app plays from; the tree receives the user-browsable copy (mp3 + txt). wasAppStorage=false means "staged + mirrored". A revoked tree removes the user root from roots(), so dirFor(false) is null: reconcile/eviction skip, never prune.
- Eviction does not delete the tree copy (user-owned files).
- Files outside owned list: di/ServicesGraph.kt (wiring), data/burns/BurnStore.kt (one-line treeUri stamp), BurnSettings strings.
- No in-UI fallback notice yet (FOLDER_FELL_BACK string added, unused).

## Questions for Levi
- Should deleting a burn also delete its copy in the user's folder? Default: no.
- Show a notice on silent fallback to app storage? Default: not yet.

## Review
fixes applied

- MAJOR roots() tied to tree reachability -> fixed: the staging root is listed whenever the local dir exists; reachability gates only new writes and the mirror. Tests: revokedOrClearedFolderKeepsStagedFilesResolvable, userFilesStayPlayableAndDeletableAfterClearingFolder.
- MAJOR binder calls on hot paths -> fixed: roots()/dirFor() make no tree calls (test readPathNeverQueriesTreeReachability asserts 0 isReachable calls).
- MAJOR readRoot() single-root aux lookup -> fixed: stems/beat grids resolved across every root (findAux). Test: auxFilesBurnedBeforePickingFolderStayVisible.
- MAJOR moveToApp data loss -> fixed: moveToApp removed; a failed tree copy keeps staged files and wasAppStorage=false (still local). Test: copyFailureKeepsStagedFilesAndUserFolderFlag.
- MAJOR storage doubling -> rejected as a code change, escalated: playback is File-based end to end (Media3 content:// would be a pipeline rewrite); staged copy kept by design. Open question for Levi: play from the tree and drop the staged copy?
- MINOR mirror only in worker path -> fixed for audio + sidecar + analog cut: BurnFolder.mirrorFiles called from the sync path, adoptStreamedFile and exportAnalogCut. Stems / beat grids deliberately not mirrored (large engine-internal files). Test: mirrorFilesCopiesStagedFilesAndSwallowsFailure.
- MINOR no fallback notice -> fixed: BurnFolder.fellBack() -> BurnResult.fellBack -> burn summary appends FOLDER_FELL_BACK. Test: fellBackIsReportedWhenChosenFolderIsUnusable. (A worker-side fallback after enqueue has no notice.)
- MINOR ledger row / test count -> fixed: ARCHITECTURE-ANDROID row now PARTIAL; tests 4716 -> 4722, 0 failures.
- MINOR stale localMemo -> fixed: BurnStore.invalidateLocalCache() called on pick/clear.
- NIT grant release -> fixed: READ|WRITE released; old URI released on Change folder.
