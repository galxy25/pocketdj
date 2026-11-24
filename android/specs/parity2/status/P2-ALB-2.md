state: implemented

# P2-ALB-2 - 'edits' document cloud sync + writable EditsStore + live re-apply

- [x] File renamed to pocketdj-edits.json; one-time migration from backup-edits.json (never clobbers an existing/pulled file) - done in CatalogEditsFile init via EditsStore.migrateLegacy
- [x] EditsStore write API (setAlbumEdit/setSongEdit/removeAlbumEdit/removeSongEdit/clearAll), deltas only, empty edit removes, via VersionedJsonWriter (inline flushNow so the reader cache is invalidated after bytes land)
- [x] SyncEntry("edits") in CollectionsGraph: applyPayload = verbatim write, onPulled = invalidate + reapplyEdits (re-derives SegmentOverrides) and returns false (never pushes back); whole-doc LWW
- [x] Backup restore writes through the store (BackupEditsStore `write` seam)
- [x] Reset hook uses editsStore.clearAll(); "edits" added to AccountDeletionService.cloudDocKeys
- [x] EditsStoreTest: 12 tests. Full suite 6177 tests, 0 failures; assembleDebug green.

## Deviations / files touched outside owned set
- AccountDeletionService.kt + AccountDeletionTest.kt: added "edits" to cloud key list (lockstep tests required it).
- Mutations are synchronous (flushNow) on the caller thread; edits are rare and small. Callers on Main may prefer Dispatchers.IO.
- Android-written docs omit `meta` (iOS stamps it on export only); pulled docs are kept verbatim until the next local write.
- No manifest/gradle/proguard change, so assembleRelease not run.

## Questions for Levi
None.
