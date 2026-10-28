state: implemented

# STU-1 — Studio models + store (pocketdj-studio.json v1 over VersionedJsonWriter) + folders (SAF roots) + reconcile

Summary: key-compatible port of iOS StudioModels / StudioStore / StudioFolders. All models decode
leniently (per-field defaults, per-element drop at every depth) and re-encode to the same JSON keys
(verified by an iOS-shaped fixture round trip with zero field loss). StudioStore persists through
the shared VersionedJsonWriter (atomic temp+rename, version-monotonic, synchronous flush()) plus
the media-free cue mirror `pocketdj-studio.cues.json`. Reconcile prunes only when a file is provably
gone from a reachable root; an unreachable user (SAF) root skips; dangling render/bounce refs are
nulled with bounceDirty=true.

Tests: 63 new JVM tests (StudioModelsCodecTest 20, StudioStoreTest 37, StudioReconcileTest 6).
Full suite `:app:testDebugUnitTest :app:assembleDebug` green: 875 tests (812 before), 0 failures.

## Checklist
- [x] StudioFactory / StudioJson (lenient accessors) / StudioSourceSerializer / StudioModels
- [x] StudioFolders (families, strict fileId, StudioDir/StudioRoots seam) + StudioSafDir (SAF, device-only)
- [x] StudioReconcile (reconcile, usageBytes, deleteAll)
- [x] StudioStore (all CRUD, cues + mirror, slices, folders, takes/staffs, playback resolve, arrangements, trimGap)
- [x] StudioGraph wiring (store lazy + reconcile on first use, ON_STOP flush, reset hook, cue sync entry, debug seed)
- [x] iOS-shape fixture app/src/test/resources/studio/ios-studio-v1.json + tests
- [x] full suite green, count moved

## Deviations / notes
- The five iOS folder structs collapse to one `StudioFolder`; folder CRUD is generic over `StudioFolderKind` (SAMPLE/LOOP/PATTERN/TAKE/ARRANGEMENT). Ids still minted per family prefix.
- Loops are `loop-<id>.wav` (family extension), documented divergence; doc is device-local.
- Store `lazy` lives in StudioGraph (D3), so AppGraph is NOT edited.
- Fixture is iOS-shaped but hand-built: the apple tests build documents in code and ship no studio JSON file.
- ScoreCursorStore (per-take score cursors) not ported; belongs to the score package.
- Corrupt (non-object) studio doc is quarantined to `pocketdj-studio.json.bak` (iOS would overwrite).
- Debug seed `--ez PDJ_SEED_STUDIO true` is a StudioGraph DeepLinkHandler gated on FLAG_DEBUGGABLE; it only fires if the shell dispatches launch intents to FeatureModule.deepLinkHandlers (not verified; no emulator use per instructions). Seeds 1 s WAV tone files named .m4a/.wav by family shape.
- SAF: `StudioGraph.userFolderTreeUri` is a settable provider (default null => app roots only). The Storage-settings folder pickers that persist a tree URI are a later package.
- Files outside the owned list: studio/model/StudioJson.kt, studio/store/StudioSafDir.kt, test helper studio/store/StudioTestEnv.kt.
- No ARCHITECTURE-ANDROID.md edit (integrator).

## Device-only
SAF tree permission persistence on real external storage (SafStudioDir); the reconcile/usage/delete logic above it is JVM-tested through the StudioDir seam.

## Questions for Levi
- Should loops stay .wav on Android, or should we later write CAF so a studio doc could ever be shared with iOS? (Default: .wav, doc stays device-local.)
