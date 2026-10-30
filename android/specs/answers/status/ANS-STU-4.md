state: in-progress

# ANS-STU-4 — Mic/import/carve samples move to the SAF user folder

- [x] StudioStore.addSampleRelocating (+ samplesFolderNotice) patterned on addTakeRelocating; idempotent re-file
- [x] StudioRoots.userFolderConfigured (configured-but-revoked => fallback + notice)
- [x] Every creator uses it: SampleFactory (import/carve), MicRecorder (fileSample + orphan recovery), DemuxExports (kit + cut), TakeRenderer (take->sample), SliceBake, ArtifactSampleConverter, MicRecordSheet
- [x] SampleRenderCache resolves SAF samples through StudioMaterializer (sourceLease / sourceFileAsync); render cache stays in app root
- [x] delete / usageBytes / reconcile already SAF-aware (STU-1); covered by new tests
- [x] Notice surfaced in SamplesScreen dialog
- [x] Tests

## Notes / deviations
- Files touched outside owned list (minimal, additive): StudioFolders.kt (StudioRoots.userFolderConfigured + DefaultStudioRoots param), StudioGraph.kt (pass materializer + userConfigured), SliceBake.kt, StudioStoreArranger.kt, MicRecordSheet.kt, SamplesScreen.kt (notice dialog, title "Import failed" -> "Samples"), SampleEditorSheet.kt / SliceEditorSheet.kt (sourceFileAsync), test helper StudioTestEnv.kt.
- Non-suspend SampleRenderCache.sourceFile on a SAF sample does a blocking copy (callers LoopFactory/SliceBaker are off-main); UI sheets use sourceFileAsync. Leases are released right after hand-out; the copy lives until the materializer LRU evicts it.
- Mic recording itself still writes to app storage during capture (crash-safe), moved at file time; no sample is ever written mid-capture to SAF.

## Questions for Levi
None.
