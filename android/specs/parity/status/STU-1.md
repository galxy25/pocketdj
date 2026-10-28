state: in-progress

# STU-1 — Studio models + store + folders + reconcile

- [x] StudioFactory / StudioJson (lenient accessors) / StudioSourceSerializer / StudioModels (all iOS models, key-compatible)
- [x] StudioFolders (families, strict fileId, StudioDir/StudioRoots seam) + StudioSafDir (SAF, device-only)
- [x] StudioReconcile (reconcile, usage, deleteAll)
- [x] StudioStore (CRUD, cues + mirror, slices, folders, takes/staffs, playback resolve, arrangements, trimGap)
- [x] StudioGraph wiring (store lazy, flush, reset, cue sync entry, debug seed)
- [ ] iOS-shape fixture + tests
- [ ] full suite + test count

## Deviations / notes
- Five folder structs collapsed to one `StudioFolder`; folder CRUD is generic over `StudioFolderKind`.
- Loops are `.wav` (documented divergence).
- Store `lazy` lives in StudioGraph (not AppGraph) per D3; no AppGraph edit needed.
- Extra files beyond the owned list: studio/model/StudioJson.kt, studio/store/StudioSafDir.kt.
- ScoreCursorStore (per-take score cursors) not ported: belongs with the score package.

## Questions for Levi
