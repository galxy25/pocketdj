state: implemented

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
